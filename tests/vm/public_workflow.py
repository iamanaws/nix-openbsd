"""Guest scripts for the public package and personal configuration workflow."""
import json
import secrets
import shlex


def prepare_public_workflow(payload, source, expected, url):
    ref = shlex.quote(source)
    # A unique output cannot already be in the image or a previous test's cache.
    nonce = secrets.token_hex(12)
    (payload / 'native-build.nix').write_text('''let
  flake = builtins.getFlake ''' + json.dumps(source) + ''';
  pkgs = flake.legacyPackages.x86_64-openbsd;
in pkgs.hello.overrideAttrs (old: {
  name = "hello-public-test-''' + nonce + '''";
  allowSubstitutes = false;
  preferLocalBuild = true;
  preBuild = (old.preBuild or "") + ''
    test "$(uname -s)" = OpenBSD
    test "$EUID" -ne 0
  '';
  postInstall = (old.postInstall or "") + ''
    printf '%s\\n' "$EUID" > "$out/build-uid"
    printf '%s\\n' "''' + nonce + '''" > "$out/build-nonce"
  '';
})
''')
    (payload / 'client.sh').write_text(f'''set -eu
 test "$(id -u)" -ne 0
 mkdir -p "$HOME/public-test"
 cd "$HOME/public-test"
 nix build --accept-flake-config {ref}#hello -o hello
 test "$(hello/bin/hello)" = 'Hello, world!'
 test "$(nix run --accept-flake-config {ref}#hello)" = 'Hello, world!'
 test "$(nix run --accept-flake-config {ref}#jq -- -n '1 + 1')" = 2
 curl --noproxy '*' -fsS {url}/native-build.nix -o native-build.nix
 test "$(nix eval --impure --raw --file native-build.nix system)" = x86_64-openbsd
 nix build --accept-flake-config --impure --file native-build.nix -L -o native-hello
 test "$(native-hello/bin/hello)" = 'Hello, world!'
 test "$(cat native-hello/build-uid)" -ne 0
 test "$(cat native-hello/build-nonce)" = {nonce}
 nix-store --verify-path "$(readlink -f native-hello)"
 echo NATIVE_BUILD_PASS
 mkdir my-openbsd
 cd my-openbsd
 nix flake init --accept-flake-config -t {ref}#native-system
 nix flake lock --override-input nix-openbsd {ref}
 openbsd-rebuild build --flake .#my-openbsd
 readlink -f result-system > ../personal-system
 echo PUBLIC_USER_WORKFLOW_PASS
''')
    phases = {
        'fresh': f'''test "$(readlink -f /run/current-system)" = {shlex.quote(expected)}
for service in nix_daemon sshd dhcpcd httpd relayd cron syslogd; do
  /etc/rc.d/$service check
 done
curl --noproxy '*' -fsS {url}/client.sh -o /tmp/client.sh
chmod 755 /tmp/client.sh
su -l bestie -c 'bash /tmp/client.sh'
personal=$(cat /home/bestie/public-test/personal-system)
"$personal/bin/switch-to-configuration" boot
''',
        'personal': '''personal=$(cat /home/bestie/public-test/personal-system)
test "$(readlink -f /run/current-system)" = "$personal"
test "$(hostname)" = my-openbsd
test "$(hello)" = 'Hello, world!'
/etc/rc.d/resolvd check
test ! -e /etc/rc.d/httpd
test ! -e /etc/rc.d/relayd
cd /home/bestie/public-test/my-openbsd
sed -i '/networking.hostName/a\\  environment.variables.PUBLIC_SWITCH_TEST = "passed";' configuration.nix
su -l bestie -c 'cd public-test/my-openbsd && openbsd-rebuild build --flake .#my-openbsd'
openbsd-rebuild dry-activate --flake .#my-openbsd
openbsd-rebuild test --flake .#my-openbsd
test "$(readlink -f /nix/var/nix/profiles/system)" = "$personal"
su -l bestie -c 'test "$PUBLIC_SWITCH_TEST" = passed'
openbsd-rebuild switch --flake .#my-openbsd
readlink -f /run/current-system > /root/switched-system
openbsd-rebuild list-generations
''',
        'switched': '''test "$(readlink -f /run/current-system)" = "$(cat /root/switched-system)"
su -l bestie -c 'test "$PUBLIC_SWITCH_TEST" = passed'
openbsd-rebuild switch --rollback
test "$(readlink -f /run/current-system)" = "$(cat /home/bestie/public-test/personal-system)"
su -l bestie -c 'test -z "${PUBLIC_SWITCH_TEST:-}"'
''',
        'rollback': '''test "$(readlink -f /run/current-system)" = "$(cat /home/bestie/public-test/personal-system)"
test "$(readlink -f /nix/var/nix/profiles/system)" = "$(readlink -f /run/current-system)"
su -l bestie -c 'test -z "${PUBLIC_SWITCH_TEST:-}" && test "$(hello)" = "Hello, world!"'
echo PUBLIC_WORKFLOW_PASS
''',
    }
    for phase, body in phases.items():
        (payload / f'{phase}.sh').write_text(
            'set -eu\n' + body + '\n/etc/rc.d/nix_daemon check\n/etc/rc.d/sshd check\n')
    return phases
