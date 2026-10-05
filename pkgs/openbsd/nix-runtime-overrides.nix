# OpenBSD runtime fixes for Nix, separate from its build dependencies.
{ nixbsdSource }:
let
  # Copy individual patches so checkout metadata cannot change Nix's derivation.
  nixPatch =
    name:
    builtins.path {
      path = nixbsdSource + "/overlays/${name}";
      inherit name;
    };
in
_: prev: {
  nix-store = (prev.nix-store.override { withAWS = false; }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Repeating the daemon's own keys needs no privilege and changes no trust.
      substituteInPlace daemon.cc \
        --replace-fail 'else if (setSubstituters(settings.getWorkerSettings().substituters))' \
          'else if (name == settings.trustedPublicKeys.name &&
              tokenizeString<StringSet>(value) == StringSet(
                  settings.trustedPublicKeys.get().begin(),
                  settings.trustedPublicKeys.get().end()))
              ;
          else if (setSubstituters(settings.getWorkerSettings().substituters))'
    '';
    patches = (old.patches or [ ]) ++ [
      (nixPatch "nix-openbsd-builder-pty.patch")
      (nixPatch "nix-openbsd-build-users.patch")
    ];
  });
  nix-main = prev.nix-main.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (nixPatch "nix-openbsd-atfork.patch")
    ];
  });
  nix-util = prev.nix-util.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./nix-openbsd-ptsname.patch ];
  });
  nix-cli = prev.nix-cli.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # OpenBSD/amd64 caps stacks at 32 MiB, including for root.
      substituteInPlace main.cc \
        --replace-fail 'nix::setStackSize(60 * 1024 * 1024);' \
          'nix::setStackSize(32 * 1024 * 1024);'
    '';
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd =
        (old.env.NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd or "")
        + " -DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED";
    };
  });
}
