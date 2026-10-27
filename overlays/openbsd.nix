final: prev:

{
  # NixOS's doas module also uses buildPackages.doas to validate its rules.
  doas = if prev.stdenv.hostPlatform.isOpenBSD then final.openbsd.doas else prev.doas;

  openbsd = prev.openbsd.overrideScope (
    openbsdFinal: openbsdPrev: {
      reboot = openbsdPrev.reboot.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          # Preserve shutdown's authorized root identity in the rc shell child.
          substituteInPlace "$BSDSRCDIR/sbin/reboot/reboot.c" \
            --replace-fail 'execl(_PATH_BSHELL, "sh", _PATH_RC, "shutdown", (char *)NULL);' \
              'if (setuid(0) == -1) err(1, "setuid");
              execl(_PATH_BSHELL, "sh", _PATH_RC, "shutdown", (char *)NULL);'
        '';
      });
      init = openbsdPrev.init.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          # activate-init-native already creates PID 1's session before activation.
          # Keep session creation for direct boots and preserve real error reporting.
          substituteInPlace "$BSDSRCDIR/sbin/init/init.c" \
            --replace-fail $'if (setsid() == -1)\n\t\twarning("initial setsid() failed: %m");' \
              $'if (getsid(0) != getpid() && setsid() == -1)\n\t\twarning("initial setsid() failed: %m");'
        '';
      });
      acme-client = openbsdFinal.callPackage ../pkgs/openbsd/acme-client.nix { };
      arch = openbsdFinal.callPackage ../pkgs/openbsd/arch.nix { };
      uname = openbsdFinal.callPackage ../pkgs/openbsd/uname.nix { };
      arp = openbsdFinal.callPackage ../pkgs/openbsd/arp.nix { };
      bgpctl = openbsdFinal.callPackage ../pkgs/openbsd/bgpctl.nix { };
      bgpd = openbsdFinal.callPackage ../pkgs/openbsd/bgpd.nix { };
      cron = openbsdFinal.callPackage ../pkgs/openbsd/cron.nix { };
      cronctl = openbsdFinal.callPackage ../pkgs/openbsd/cronctl.nix { };
      crontab = openbsdFinal.callPackage ../pkgs/openbsd/crontab.nix { };
      dhcpd = openbsdFinal.callPackage ../pkgs/openbsd/dhcpd.nix { };
      doas = openbsdFinal.callPackage ../pkgs/openbsd/doas.nix { };
      httpd = openbsdFinal.callPackage ../pkgs/openbsd/httpd.nix { };
      ikectl = openbsdFinal.callPackage ../pkgs/openbsd/ikectl.nix { };
      iked = openbsdFinal.callPackage ../pkgs/openbsd/iked.nix { };
      ipsecctl = openbsdFinal.callPackage ../pkgs/openbsd/ipsecctl.nix { };
      isakmpd = openbsdFinal.callPackage ../pkgs/openbsd/isakmpd.nix { };
      libagentx = openbsdFinal.callPackage ../pkgs/openbsd/libagentx.nix { };
      libedit = openbsdFinal.callPackage ../pkgs/openbsd/libedit.nix { };
      libkeynote = openbsdFinal.callPackage ../pkgs/openbsd/libkeynote.nix { };
      libpcap = openbsdFinal.callPackage ../pkgs/openbsd/libpcap.nix { };
      libradius = openbsdFinal.callPackage ../pkgs/openbsd/libradius.nix { };
      netstat = openbsdFinal.callPackage ../pkgs/openbsd/netstat.nix { };
      ntpctl = openbsdFinal.ntpd;
      ntpd = openbsdFinal.callPackage ../pkgs/openbsd/ntpd.nix { };
      ospfctl = openbsdFinal.callPackage ../pkgs/openbsd/ospfctl.nix { };
      ospfd = openbsdFinal.callPackage ../pkgs/openbsd/ospfd.nix { };
      pflogd = openbsdFinal.callPackage ../pkgs/openbsd/pflogd.nix { };
      ping = openbsdFinal.callPackage ../pkgs/openbsd/ping.nix { };
      rad = openbsdFinal.callPackage ../pkgs/openbsd/rad.nix { };
      relayctl = openbsdFinal.callPackage ../pkgs/openbsd/relayctl.nix { };
      relayd = openbsdFinal.callPackage ../pkgs/openbsd/relayd.nix { };
      resolvd = openbsdFinal.callPackage ../pkgs/openbsd/resolvd.nix { };
      ripctl = openbsdFinal.callPackage ../pkgs/openbsd/ripctl.nix { };
      ripd = openbsdFinal.callPackage ../pkgs/openbsd/ripd.nix { };
      sensorsd = openbsdFinal.callPackage ../pkgs/openbsd/sensorsd.nix { };
      snmp = openbsdFinal.callPackage ../pkgs/openbsd/snmp.nix { };
      snmp_mibs = openbsdFinal.callPackage ../pkgs/openbsd/snmp_mibs.nix { };
      snmpd = openbsdFinal.callPackage ../pkgs/openbsd/snmpd.nix { };
      snmpd_metrics = openbsdFinal.callPackage ../pkgs/openbsd/snmpd_metrics.nix { };
      syslogc = openbsdFinal.callPackage ../pkgs/openbsd/syslogc.nix { };
      syslogd = openbsdPrev.syslogd.overrideAttrs (old: {
        postPatch = ''
          sed -i /DPADD/d "$BSDSRCDIR/usr.sbin/syslogd/syslogd/Makefile"

          # NetBSD make otherwise mistakes the source directories for built executables.
          for program in syslogd syslogd-parent; do
            echo ".NOPATH: $program" >> "$BSDSRCDIR/usr.sbin/syslogd/$program/Makefile"
          done

          # The daemon and its privileged parent are both installed in $out/bin.
          substituteInPlace "$BSDSRCDIR/usr.sbin/syslogd/privsep.c" \
            --replace-fail '"/sbin/syslogd"' '"/bin/syslogd"' \
            --replace-fail '"/libexec/syslogd-parent"' '"/bin/syslogd-parent"'
        '';
        meta = (old.meta or { }) // {
          mainProgram = "syslogd";
        };
      });
      tcpdump = openbsdFinal.callPackage ../pkgs/openbsd/tcpdump.nix { };
      traceroute = openbsdFinal.callPackage ../pkgs/openbsd/traceroute.nix { };
      unwind = openbsdFinal.callPackage ../pkgs/openbsd/unwind.nix { };
      w = openbsdFinal.callPackage ../pkgs/openbsd/w.nix { };
    }
  );
}
