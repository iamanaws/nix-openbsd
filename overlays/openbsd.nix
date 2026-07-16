final: prev:

{
  # The pinned nixpkgs revision has a failing wolfSSL unit test on the Linux
  # build host, which otherwise prevents QEMU from being built for the VM.
  wolfssl = prev.wolfssl.overrideAttrs (_old: {
    doCheck = false;
  });

  openbsd = prev.openbsd.overrideScope (
    openbsdFinal: _openbsdPrev: {
      httpd = openbsdFinal.callPackage ../pkgs/openbsd/httpd.nix { };
      libagentx = openbsdFinal.callPackage ../pkgs/openbsd/libagentx.nix { };
      relayctl = openbsdFinal.callPackage ../pkgs/openbsd/relayctl.nix { };
      relayd = openbsdFinal.callPackage ../pkgs/openbsd/relayd.nix { };
    }
  );
}
