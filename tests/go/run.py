"""Build Go consumers through the daemon as a regular OpenBSD user."""
import argparse
from pathlib import Path
import shlex
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import Guest, clone_state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--vm-state', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    source, inputs = args.source.resolve(strict=True), args.inputs.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-go.'))
    print('Go runtime tests: ' + str(work), flush=True)
    state = work / 'state'
    clone_state(args.vm_state, state)
    user_commands = f'''
set -eu
test "$(id -u)" -ne 0
go_work=$(mktemp -d /var/tmp/openbsd-go.XXXXXXXX)
trap 'rm -rf "$go_work"' EXIT
export NIX_REMOTE=daemon GOTOOLCHAIN=local
export GOCACHE="$go_work/cache" GOPATH="$go_work/workspace"
{shlex.quote(str(inputs / 'toolchain/bin/go'))} version
CGO_ENABLED=0 {shlex.quote(str(inputs / 'toolchain/bin/go'))} build -o "$go_work/pure" {shlex.quote(str(source / 'tests/go/pure/main.go'))}
"$go_work/pure" | grep -Fx 'Go openbsd/amd64: HÉLLO'
nix build --accept-flake-config --impure --no-link --file {shlex.quote(str(source / 'tests/go'))} --argstr flakeRef {shlex.quote(str(source))} --argstr nonce regular-user pure cgo --max-jobs 1 --cores 2 -L
printf 'echo   hello\\n' | {shlex.quote(str(inputs / 'shfmt/bin/shfmt'))} -ln posix | grep -Fx 'echo hello'
'''.strip()
    success = False
    try:
        with Guest(args.launcher, state, work / 'console.log') as guest:
            guest.run('su -l bestie -c ' + shlex.quote(user_commands), args.timeout)
        success = True
        print('GO_RUNTIME_PASS', flush=True)
    finally:
        if success and not args.keep:
            shutil.rmtree(state)


if __name__ == '__main__':
    main()
