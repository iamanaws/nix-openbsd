final: prev:
let
  upstream = prev.path + "/pkgs/os-specific/bsd/openbsd/pkgs";
  adapters = import (prev.path + "/pkgs/stdenv/adapters.nix") {
    inherit (prev) lib config;
    pkgs = final;
  };
in
{
  zlib =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.zlib.overrideAttrs (old: {
        # The shared-library probe uses zlib's full version script: madler/zlib#960.
        env = (old.env or { }) // {
          NIX_LDFLAGS = (old.env.NIX_LDFLAGS or "") + " --undefined-version";
        };
      })
    else
      prev.zlib;
  llvmPackages_21 =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.llvmPackages_21.overrideScope (
        _: llvmPrev: {
          compiler-rt-no-libc = llvmPrev.compiler-rt-no-libc.overrideAttrs (old: {
            buildInputs = (old.buildInputs or [ ]) ++ [ final.openbsd.include ];
            # The pinned recipe removes assert.h; 8.0 libc uses the CPU-detection builtins.
            postPatch = (old.postPatch or "") + ''
              sed -i '1i#include <assert.h>' lib/builtins/cpu_model/x86.c lib/builtins/clear_cache.c
            '';
          });
        }
      )
    else
      prev.llvmPackages_21;
  # Nixpkgs now includes these fixes; the pinned NixBSD overlay still duplicates them.
  stdenvAdapters = prev.stdenvAdapters // {
    inherit (adapters) makeStatic makeStaticBinaries;
  };
  freebsd =
    prev.freebsd
    // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux (
      prev.lib.genAttrs [ "makefs" "mkimg" ] (
        name:
        prev.freebsd.${name}.overrideAttrs (old: {
          # These portable image tools still build on Linux; the new default is FreeBSD-only.
          meta = old.meta // {
            platforms = old.meta.platforms ++ prev.lib.platforms.linux;
          };
        })
      )
    );
  tcl = prev.tcl.overrideAttrs (old: {
    # The pinned NixBSD overlay hardcodes the previous OpenBSD release.
    configureFlags = map (
      flag:
      if flag == "tcl_cv_sys_version=OpenBSD-7.9" then
        "tcl_cv_sys_version=OpenBSD-${final.openbsd.version}"
      else
        flag
    ) old.configureFlags;
  });
  openbsd = prev.openbsd.overrideScope (
    openbsdFinal: openbsdPrev: {
      inherit (final.callPackage ../pkgs/openbsd/source.nix { }) source version;
      libcMinimal = openbsdPrev.libcMinimal.overrideAttrs (old: {
        patches = map (
          patch:
          if prev.lib.hasSuffix "-skip-tags.patch" (toString patch) then
            ../pkgs/openbsd/libc-no-tags.patch
          else
            patch
        ) old.patches;
      });
      stand = openbsdFinal.callPackage (upstream + "/stand/package.nix") { };
      rc = (openbsdFinal.callPackage (upstream + "/rc/package.nix") { }).overrideAttrs (old: {
        patches = map (
          patch:
          if builtins.baseNameOf patch == "boot-phases.patch" then
            ../pkgs/openbsd/rc-boot-phases.patch
          else
            patch
        ) old.patches;
        # Keep NixBSD's runtime integration with the updated OpenBSD rc script.
        # Its /tmp cleanup also needs GNU find/xargs syntax.
        postPatch = ''
          substituteInPlace "$BSDSRCDIR/etc/rc" \
            --replace-fail 'stat -f %Hr' '${openbsdFinal.stat}/bin/stat -f %Hr' \
            --replace-fail 'stat -f %Lr' '${openbsdFinal.stat}/bin/stat -f %Lr' \
            --replace-fail 'stat -qf %Hr,%Lr' '${openbsdFinal.stat}/bin/stat -qf %Hr,%Lr' \
            --replace-fail 'proto icmp6' 'proto 58' \
            --replace-fail 'proto carp' 'proto 112' \
            --replace-fail 'xargs -r0J % find -d %' 'xargs -r0I % find % -depth' \
            --replace-fail 'xargs -r0J % mv' 'xargs -r0I % mv'
          substituteInPlace "$BSDSRCDIR/etc/rc.d/rc.subr" \
            --replace-fail \
              'local _rcexec="su -fl -c ''${daemon_class} -s /bin/sh ''${daemon_user} -c"' \
              'local _rcexec="${openbsdFinal.su}/bin/su -fl -c ''${daemon_class} -s ${final.runtimeShell} ''${daemon_user} -c"' \
            --replace-fail '"''${_set_monitor}; \' \
              '"''${_set_monitor}; ''${nixbsd_environment:-:}; \' \
            --replace-fail '"$(id -R)"' '"$(${openbsdFinal.id}/bin/id -R)"' \
            --replace-fail '"$(id -u)"' '"$(${openbsdFinal.id}/bin/id -u)"'
          # rc.d prints service names without a newline; delimit the early
          # NixBSD phases just like OpenBSD's other daemon groups.
          substituteInPlace "$BSDSRCDIR/etc/rc" \
            --replace-fail 'daemon_phase 10' $'echo -n "starting system services:"\ndaemon_phase 10' \
            --replace-fail 'daemon_phase 20' $'daemon_phase 20\necho "."' \
            --replace-fail "echo 'starting network'" "echo -n 'starting network:'" \
            --replace-fail 'daemon_phase 30' $'daemon_phase 30\necho "."'
          # vmd is not installed unless its service is configured.
          substituteInPlace "$BSDSRCDIR/etc/rc" \
            --replace-fail 'if /etc/rc.d/vmd check > /dev/null; then' \
              'if [[ -x /etc/rc.d/vmd ]] && /etc/rc.d/vmd check > /dev/null; then'
          # Networking is configured by NixBSD services. Traditional setup and
          # recovery tools are only available when explicitly installed.
          substituteInPlace "$BSDSRCDIR/etc/rc" \
            --replace-fail 'sh /etc/netstart' '[[ ! -f /etc/netstart ]] || sh /etc/netstart' \
            --replace-fail 'if [[ ! -f $_isakmpd_key ]]; then' \
              'if [[ ''${isakmpd_flags:-NO} != NO && ! -f $_isakmpd_key ]]; then' \
            --replace-fail 'if [[ ! -f $_iked_key ]]; then' \
              'if [[ ''${iked_flags:-NO} != NO && ! -f $_iked_key ]]; then' \
            --replace-fail 'if [[ -d /var/crash ]]; then' \
              'if [[ -d /var/crash ]] && command -v savecore >/dev/null; then' \
            --replace-fail "echo 'preserving editor files.'; /usr/libexec/vi.recover" \
              "if [[ -x /usr/libexec/vi.recover ]]; then echo 'preserving editor files.'; /usr/libexec/vi.recover; fi"
        '';
      });
      sys =
        (openbsdFinal.callPackage (upstream + "/sys/package.nix") {
          # The pinned recipe uses LLVM 18; match Nixpkgs' LLVM 22 kernel compiler.
          overrideCC = stdenv: _: final.overrideCC stdenv final.buildPackages.llvmPackages_22.clangNoLibc;
        }).overrideAttrs
          (old: {
            # NixBSD still needs TMPFS for /run/wrappers.
            postPatch = old.postPatch + ''
              substituteInPlace "$BSDSRCDIR/sys/conf/GENERIC" \
                --replace-fail '#option		TMPFS' 'option		TMPFS'
            '';
          });
    }
  );
}
