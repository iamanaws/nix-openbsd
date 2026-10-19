"""Check runtime and optional bootstrap cache availability.

Run with Python 3 and Nix on PATH. This checks narinfo availability, not NAR
downloads or signatures; the fresh VM test exercises actual substitution.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
from urllib.error import HTTPError
from urllib.request import Request, urlopen


CACHES = ('https://nix-openbsd.cachix.org', 'https://cache.nixos.org')


def locate(path):
    for cache in CACHES:
        url = cache + '/' + path.removeprefix('/nix/store/').split('-')[0] + '.narinfo'
        try:
            with urlopen(Request(url, headers={'User-Agent': 'nix-openbsd-cache-check/1.0'}),
                         timeout=30) as response:
                fields = dict(line.split(': ', 1) for line in
                              response.read().decode().splitlines() if ': ' in line)
        except HTTPError as error:
            if error.code == 404:
                continue
            raise
        if fields.get('StorePath') != path:
            raise ValueError('Unexpected StorePath in ' + url)
        return cache, ['/nix/store/' + ref for ref in fields.get('References', '').split()]
    return None, []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('flake', help='prefer a published, revision-pinned flake reference')
    parser.add_argument('--report', help='write the full JSON availability report')
    parser.add_argument('--bootstrap', action='store_true',
                        help='also check the seed outputs required during evaluation')
    args = parser.parse_args()
    roots = json.loads(subprocess.check_output([
        'nix', 'eval', '--accept-flake-config', '--json',
        f'{args.flake}#packages.x86_64-openbsd', '--apply',
        'packages: builtins.mapAttrs (_: package: package.outPath) packages'], text=True))
    bootstrap = {}
    if args.bootstrap:
        seeds = json.loads(subprocess.check_output([
            'nix', 'eval', '--accept-flake-config', '--impure', '--json', '--expr',
            f'let f = builtins.getFlake {json.dumps(args.flake)}; in '
            'import (f.outPath + "/pkgs/openbsd/native-bootstrap.nix") '
            '{ pkgs = f.nixosConfigurations.openbsd-base.pkgs; }'], text=True))
        bootstrap = {f'{name}.{output}': value for name, seed in seeds.items()
                     for output, value in seed.items()
                     if isinstance(value, str) and value.startswith('/nix/store/')}
    pending = set(roots.values()) | set(bootstrap.values())
    locations = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        while pending:
            batch = sorted(pending)
            pending = set()
            for path, (cache, refs) in zip(batch, pool.map(locate, batch)):
                locations[path] = cache
                pending.update(refs)
            pending.difference_update(locations)
    missing = sorted(path for path, cache in locations.items() if cache is None)
    report = dict(flake=args.flake, roots=roots, locations=locations, missing=missing)
    if args.bootstrap:
        report['bootstrap'] = bootstrap
    if args.report:
        with open(args.report, 'w') as stream:
            json.dump(report, stream, indent=2)
            stream.write('\n')
    for name, path in roots.items():
        print(f'{name}: {locations[path] or "MISSING"} ({path})')
    if args.bootstrap:
        print(f'{len(set(bootstrap.values()))} bootstrap outputs checked')
    for cache in CACHES:
        print(f'{cache}: {sum(value == cache for value in locations.values())} paths')
    for path in missing:
        print('MISSING:', path)
    print(f'{len(locations)} paths checked; {len(missing)} missing')
    raise SystemExit(bool(missing))


if __name__ == '__main__':
    main()
