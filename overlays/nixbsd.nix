final: prev:
let
  upstream = prev.path + "/pkgs/os-specific/bsd/openbsd/pkgs";
  adapters = import (prev.path + "/pkgs/stdenv/adapters.nix") {
    inherit (prev) lib config;
    pkgs = final;
  };
in
{
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
  openbsd = prev.openbsd.overrideScope (
    openbsdFinal: openbsdPrev: {
      stand = openbsdFinal.callPackage (upstream + "/stand/package.nix") { };
      rc = openbsdPrev.rc.overrideAttrs {
        patches = (openbsdFinal.callPackage (upstream + "/rc/package.nix") { }).patches;
      };
      sys = (openbsdFinal.callPackage (upstream + "/sys/package.nix") { }).overrideAttrs (old: {
        # NixBSD still needs TMPFS for /run/wrappers.
        postPatch = old.postPatch + ''
          substituteInPlace "$BSDSRCDIR/sys/conf/GENERIC" \
            --replace-fail '#option		TMPFS' 'option		TMPFS'
        '';
      });
    }
  );
}
