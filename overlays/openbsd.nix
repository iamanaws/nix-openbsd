{ compatibleMakefs }:
final: prev:

{
  # cmocka enables and builds its target-side test programs whenever doCheck
  # is true. Those programs are not runnable during an OpenBSD cross build.
  cmocka =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.cmocka.overrideAttrs (old: {
        doCheck = false;
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DWITH_EXAMPLES=OFF" ];
      })
    else
      prev.cmocka;

  curl =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.curl.override {
        gssSupport = false;
        http3Support = false;
        idnSupport = false;
        pslSupport = false;
      }
    else
      prev.curl;

  freebsd =
    if prev.stdenv.hostPlatform.isLinux then
      prev.freebsd // {
        # FreeBSD 15 makefs emits a UFS1 superblock that OpenBSD 7.9 rejects.
        # Keep the last known-compatible FreeBSD 14.1 image builder.
        makefs = compatibleMakefs;
        mkimg = prev.freebsd.mkimg.overrideAttrs (old: {
          # Keep the interface expected by both openbsd-phase6 and current
          # nixbsd/main: -r relocates offsets recorded in the BSD disklabel.
          postPatch = (old.postPatch or "") + ''
            substituteInPlace "$BSDSRCDIR/usr.bin/mkimg/bsd.c" \
              --replace-fail \
                'le32enc(&d->d_magic, BSD_MAGIC);' \
                $'le32enc(&d->d_magic, BSD_MAGIC);\n\tle32enc(&d->d_type, DTYPE_SCSI);\n\t/* OpenBSD 7.9 only accepts v1 disklabels. */\n\tle32enc(&d->d_spare[0], 1U << 16);' \
              --replace-fail \
                'le32enc(&dp->p_offset, part->block);' \
                'le32enc(&dp->p_offset, part->block + relocation);'
            substituteInPlace "$BSDSRCDIR/usr.bin/mkimg/mkimg.c" \
              --replace-fail \
                'uint32_t active_partition = 0;' \
                $'uint32_t active_partition = 0;\nint32_t relocation = 0;' \
              --replace-fail \
                $'\tfprintf(stderr, "\\t-s <scheme>\\n");' \
                $'\tfprintf(stderr, "\\t-s <scheme>\\n");\n\tfprintf(stderr, "\\t-r <relocation>\\n");' \
              --replace-fail \
                '"a:b:c:C:f:o:p:s:t:vyH:P:S:T:"' \
                '"a:b:c:C:f:o:p:s:t:vyH:P:S:T:r:"' \
              --replace-fail \
                $'\t\tcase LONGOPT_FORMATS:' \
                $'\t\tcase \'r\':\n\t\t\trelocation = atoi(optarg);\n\t\t\tbreak;\n\t\tcase LONGOPT_FORMATS:'
            substituteInPlace "$BSDSRCDIR/usr.bin/mkimg/mkimg.h" \
              --replace-fail \
                'extern uint32_t active_partition;' \
                $'extern uint32_t active_partition;\nextern int32_t relocation;'
            substituteInPlace "$BSDSRCDIR/usr.bin/mkimg/scheme.h" \
              --replace-fail $'\tALIAS_NTFS,' \
                $'\tALIAS_NTFS,\n\tALIAS_OPENBSD_DATA,'
            substituteInPlace "$BSDSRCDIR/usr.bin/mkimg/scheme.c" \
              --replace-fail $'\t{ "ntfs", ALIAS_NTFS },' \
                $'\t{ "ntfs", ALIAS_NTFS },\n\t{ "openbsd-data", ALIAS_OPENBSD_DATA },'
            substituteInPlace "$BSDSRCDIR/usr.bin/mkimg/gpt.c" \
              --replace-fail \
                'static mkimg_uuid_t gpt_uuid_mbr = GPT_ENT_TYPE_MBR;' \
                $'static mkimg_uuid_t gpt_uuid_mbr = GPT_ENT_TYPE_MBR;\nstatic mkimg_uuid_t gpt_uuid_openbsd_data = GPT_ENT_TYPE_OPENBSD_DATA;' \
              --replace-fail \
                $'    {\tALIAS_MBR, ALIAS_PTR2TYPE(&gpt_uuid_mbr) },' \
                $'    {\tALIAS_MBR, ALIAS_PTR2TYPE(&gpt_uuid_mbr) },\n    {\tALIAS_OPENBSD_DATA, ALIAS_PTR2TYPE(&gpt_uuid_openbsd_data) },'
          '';
        });
      }
    else
      prev.freebsd;

  boehmgc =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.boehmgc.overrideAttrs (old: {
        preInstall = (old.preInstall or "") + ''
          gcLibraries=(.libs/libgc.so.*)
          (( ''${#gcLibraries[@]} == 1 ))
          ln -s "''${gcLibraries[0]##*/}" .libs/libgc.so
          mkdir -p "$out/lib"
          ln -s "$PWD/''${gcLibraries[0]}" "$out/lib/libgc.so"
        '';
        postInstall = (old.postInstall or "") + ''
          pushd "$out/lib"
          for library in gc gccpp gctba cord; do
            versionedLibraries=("lib$library.so."*)
            (( ''${#versionedLibraries[@]} == 1 ))
            ln -sfn "''${versionedLibraries[0]}" "lib$library.so"
          done
          popd
        '';
      })
    else
      prev.boehmgc;

  libiconv =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.libiconv.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          # GNU ld does not resolve OpenBSD's versioned-only shared objects
          # from the conventional -liconv and -lcharset linker arguments.
          pushd "$out/lib"
          iconvLibraries=(libiconv.so.*)
          charsetLibraries=(libcharset.so.*)
          (( ''${#iconvLibraries[@]} == 1 ))
          (( ''${#charsetLibraries[@]} == 1 ))
          ln -s "''${iconvLibraries[0]}" libiconv.so
          ln -s "''${charsetLibraries[0]}" libcharset.so
          popd
        '';
      })
    else
      prev.libiconv;

  libarchive =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.libarchive.overrideAttrs (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [ final.libiconv ];
        preConfigure = (old.preConfigure or "") + ''
          export LIBS="-Wl,-liconv -Wl,--allow-shlib-undefined"
        '';
        configureFlags =
          (old.configureFlags or [ ])
          ++ [
            "--without-lzma"
            "--without-xml2"
          ];
      })
    else
      prev.libarchive;

  libpng =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.libpng.overrideAttrs (old: {
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd =
            (old.env.NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd or "")
            + " -D_BSD_SOURCE";
        };
      })
    else
      prev.libpng;

  gawk =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.gawk.overrideAttrs (old: {
        # Nixpkgs exposes the _LIBC-only bintime helpers in sys/time.h.
        # Keep their BSD typedefs visible when gawk requests POSIX headers.
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd =
            (old.env.NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd or "")
            + " -D_BSD_SOURCE";
        };
      })
    else
      prev.gawk;

  gettext =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.gettext.overrideAttrs (old: {
        preInstall = (old.preInstall or "") + ''
          intlLibraries=(gettext-runtime/intl/.libs/libintl.so.*)
          textstyleLibraries=(libtextstyle/lib/.libs/libtextstyle.so.*)
          gettextlibLibraries=(gettext-tools/gnulib-lib/.libs/libgettextlib-*.so)
          gettextsrcLibraries=(gettext-tools/src/.libs/libgettextsrc-*.so)
          (( ''${#intlLibraries[@]} == 1 ))
          (( ''${#textstyleLibraries[@]} == 1 ))
          (( ''${#gettextlibLibraries[@]} == 1 ))
          (( ''${#gettextsrcLibraries[@]} == 1 ))
          mkdir -p "$out/lib"
          ln -s "$PWD/''${intlLibraries[0]}" "$out/lib/libintl.so"
          ln -s "$PWD/''${textstyleLibraries[0]}" "$out/lib/libtextstyle.so"
          ln -s "$PWD/''${gettextlibLibraries[0]}" "$out/lib/libgettextlib.so"
          ln -s "$PWD/''${gettextsrcLibraries[0]}" "$out/lib/libgettextsrc.so"
        '';
        postInstall = (old.postInstall or "") + ''
          pushd "$out/lib"
          for library in intl textstyle gettextlib gettextsrc; do
            rm "lib$library.so"
            versionedLibraries=("lib$library"*.so*)
            (( ''${#versionedLibraries[@]} == 1 ))
            ln -sfn "''${versionedLibraries[0]}" "lib$library.so"
          done
          popd
        '';
      })
    else
      prev.gettext;

  gzip =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.gzip.overrideAttrs (old: {
        configureFlags =
          (old.configureFlags or [ ])
          ++ [ "gl_cv_func_fflush_stdin=yes" ];
      })
    else
      prev.gzip;

  libxcrypt =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.libxcrypt.overrideAttrs (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [ "LIBS=-Wl,-lc" ];
      })
    else
      prev.libxcrypt;

  libxml2 =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.libxml2.overrideAttrs (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [ final.libiconv ];
        postInstall = (old.postInstall or "") + ''
          pushd "$out/lib"
          xmlLibraries=(libxml2.so.*)
          (( ''${#xmlLibraries[@]} == 1 ))
          ln -s "''${xmlLibraries[0]}" libxml2.so
          popd
        '';
      })
    else
      prev.libxml2;

  libxslt =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.libxslt.overrideAttrs (old: {
        preInstall = (old.preInstall or "") + ''
          xsltLibraries=(libxslt/.libs/libxslt.so.*)
          (( ''${#xsltLibraries[@]} == 1 ))
          mkdir -p "$out/lib"
          ln -s "$PWD/''${xsltLibraries[0]}" "$out/lib/libxslt.so"
        '';
        postInstall = (old.postInstall or "") + ''
          pushd "$out/lib"
          for library in xslt exslt; do
            versionedLibraries=("lib$library.so."*)
            (( ''${#versionedLibraries[@]} == 1 ))
            ln -sfn "''${versionedLibraries[0]}" "lib$library.so"
          done
          popd
        '';
      })
    else
      prev.libxslt;

  oniguruma =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.oniguruma.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          pushd "$lib/lib"
          onigLibraries=(libonig.so.*)
          (( ''${#onigLibraries[@]} == 1 ))
          ln -s "''${onigLibraries[0]}" libonig.so
          popd
        '';
      })
    else
      prev.oniguruma;

  nix =
    if prev.stdenv.hostPlatform.isOpenBSD then
      (prev.nix.overrideScope (
        _nixFinal: nixPrev: {
          nix-store = nixPrev.nix-store.override { withAWS = false; };
          nix-util = nixPrev.nix-util.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              # OpenBSD, like macOS, provides ptsname(3) but not ptsname_r(3).
              substituteInPlace terminal.cc \
                --replace-fail '#  ifdef __APPLE__' \
                  '#  if defined(__APPLE__) || defined(__OpenBSD__)'
            '';
          });
          nix-cli = nixPrev.nix-cli.overrideAttrs (old: {
            env = (old.env or { }) // {
              NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd =
                (old.env.NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd or "")
                + " -DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED";
            };
          });
        }
      ))
    else
      prev.nix;

  openssl =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.openssl.overrideAttrs (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [ "-Wl,-lc" ];
      })
    else
      prev.openssl;

  openssh =
    if prev.stdenv.hostPlatform.isOpenBSD then
      (prev.openssh.override { withLdns = false; }).overrideAttrs (old: {
        configureFlags =
          builtins.filter (flag: flag != "--with-libedit=yes") (
            old.configureFlags or [ ]
          )
          ++ [ "--with-libedit=no" ];
      })
    else
      prev.openssh;

  perl =
    if prev.stdenv.hostPlatform.isOpenBSD then
      let
        perl =
          (prev.perl.override { self = perl; }).overrideAttrs (old: {
            # OpenBSD 7.9 does not declare clock_nanosleep(2), but Perl's cross
            # configure probe inherits the build host's positive result.
            configureFlags =
              (old.configureFlags or [ ])
              ++ [ "-Ud_clock_nanosleep" ];
          });
      in
      perl
    else
      prev.perl;

  perlPackages =
    if prev.stdenv.hostPlatform.isOpenBSD then
      final.perl.pkgs
    else
      prev.perlPackages;

  tcl =
    if prev.stdenv.hostPlatform.isOpenBSD then
      prev.tcl.overrideAttrs (old: {
        configureFlags =
          (old.configureFlags or [ ])
          ++ [ "tcl_cv_sys_version=OpenBSD-7.9" ];
        postPatch = (old.postPatch or "") + ''
          dollar='$'
          substituteInPlace unix/tcl.m4 unix/configure \
            --replace-fail \
              "$dollar{TCL_TRIM_DOTS}.so$dollar{SHLIB_VERSION}" \
              "$dollar{TCL_TRIM_DOTS}.so"
        '';
        postInstall = ''
          make install-private-headers
          ln -s "$out/lib/libtcl86.so" "$out/lib/libtcl.so"
        '';
      })
    else
      prev.tcl;

  # The pinned NixBSD base configuration still installs neofetch, which was
  # removed from current Nixpkgs. Keep the command available until that base
  # configuration migrates to a maintained replacement.
  neofetch = prev.writeShellScriptBin "neofetch" ''
    echo "OpenBSD $(uname -r) $(uname -m)"
  '';

  # NixBSD's mini-tmpfiles integration is explicitly validation-only and its
  # Rust cross toolchain does not currently support OpenBSD 7.9.
  mini-tmpfiles = prev.writeShellScriptBin "mini-tmpfiles" ''
    exit 0
  '';

  # NixBSD still uses the legacy derivation helper in its installer scripts.
  substituteAll =
    args:
    prev.stdenvNoCC.mkDerivation (
      {
        name = args.name or (baseNameOf (toString args.src));
        dontUnpack = true;
        preferLocalBuild = true;
        allowSubstitutes = false;
        buildCommand = ''
          eval "$preInstall"
          target="$out"
          if [ -n "$dir" ]; then
            target="$out/$dir/$name"
            mkdir -p "$out/$dir"
          fi
          substituteAll "$src" "$target"
          if [ -n "$isExecutable" ]; then
            chmod +x "$target"
          fi
          eval "$postInstall"
        '';
      }
      // args
    );

  openbsd = prev.openbsd.overrideScope (
    openbsdFinal: openbsdPrev: {
      acme-client = openbsdFinal.callPackage ../pkgs/openbsd/acme-client.nix { };
      arp = openbsdFinal.callPackage ../pkgs/openbsd/arp.nix { };
      bgpctl = openbsdFinal.callPackage ../pkgs/openbsd/bgpctl.nix { };
      bgpd = openbsdFinal.callPackage ../pkgs/openbsd/bgpd.nix { };
      cron = openbsdFinal.callPackage ../pkgs/openbsd/cron.nix { };
      crontab = openbsdFinal.callPackage ../pkgs/openbsd/crontab.nix { };
      dhcpd = openbsdFinal.callPackage ../pkgs/openbsd/dhcpd.nix { };
      doas = openbsdFinal.callPackage ../pkgs/openbsd/doas.nix { };
      httpd = openbsdFinal.callPackage ../pkgs/openbsd/httpd.nix { };
      init = openbsdFinal.callPackage ../pkgs/openbsd/init.nix { };
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
      rc = openbsdPrev.rc.overrideAttrs (old: {
        patches =
          [ ../pkgs/openbsd/boot-phases-7.9.patch ]
          ++ builtins.tail (old.patches or [ ]);
      });
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
      stand = openbsdPrev.stand.overrideAttrs (old: {
        patches = [ ../pkgs/openbsd/initpath-7.9.patch ];
        postPatch = (old.postPatch or "") + ''
          substituteInPlace "$BSDSRCDIR/sys/stand/boot/cmd.h" \
            --replace-fail '#define CMD_BUFF_SIZE		133' \
            '#define CMD_BUFF_SIZE		399'
          substituteInPlace "$BSDSRCDIR/sys/arch/amd64/stand/Makefile" \
            --replace-fail 'SUBDIR+=rdboot vmboot' ""
          substituteInPlace \
            "$BSDSRCDIR/sys/arch/amd64/stand/mbr/Makefile" \
            "$BSDSRCDIR/sys/arch/amd64/stand/biosboot/Makefile" \
            --replace-fail '-Ttext 0' '-Ttext 0 --image-base=0'
          substituteInPlace \
            "$BSDSRCDIR/sys/arch/amd64/stand/boot/Makefile" \
            "$BSDSRCDIR/sys/arch/amd64/stand/cdboot/Makefile" \
            "$BSDSRCDIR/sys/arch/amd64/stand/pxeboot/Makefile" \
            --replace-fail '-Ttext $(LINKADDR)' \
            '-Ttext $(LINKADDR) --image-base=0'
          substituteInPlace \
            "$BSDSRCDIR/sys/arch/amd64/stand/cdbr/Makefile" \
            --replace-fail '-Ttext ''${ORG}' \
            '-Ttext ''${ORG} --image-base=0'
          substituteInPlace \
            "$BSDSRCDIR/sys/arch/amd64/stand/efiboot/Makefile.common" \
            --replace-fail '    --target=''${OBJFMT} ''${PROG.so} ''${.TARGET}' \
            '    --input-target=''${INPUTFMT} --output-target=''${OBJFMT} --subsystem=efi-app ''${PROG.so}.elf ''${.TARGET}'
          sed -i '/^''${PROG}: ''${PROG.so}$/a\
	''${LLVM_OBJCOPY} --output-target=''${INPUTFMT} ''${PROG.so} ''${PROG.so}.elf' \
            "$BSDSRCDIR/sys/arch/amd64/stand/efiboot/Makefile.common"
          substituteInPlace \
            "$BSDSRCDIR/sys/arch/amd64/stand/efiboot/bootx64/Makefile" \
            --replace-fail 'OBJFMT=		efi-app-x86_64' \
            'OBJFMT=		pei-x86-64
INPUTFMT=	elf64-x86-64'
          substituteInPlace \
            "$BSDSRCDIR/sys/arch/amd64/stand/efiboot/bootia32/Makefile" \
            --replace-fail 'OBJFMT=		efi-app-ia32' \
            'OBJFMT=		pei-i386
INPUTFMT=	elf32-i386'
        '';
        preBuild = (old.preBuild or "") + ''
          export OBJCOPY="${
            final.buildPackages.binutils-unwrapped-all-targets
          }/bin/${final.stdenv.cc.targetPrefix}objcopy"
          export LLVM_OBJCOPY="${
            final.buildPackages.llvmPackages.llvm
          }/bin/llvm-objcopy"
        '';
      });
      sys = openbsdPrev.sys.overrideAttrs (old: {
        patches = [ ../pkgs/openbsd/initpath-7.9.patch ];
        postPatch = (old.postPatch or "") + ''
          substituteInPlace "$BSDSRCDIR/sys/conf/GENERIC" \
            --replace-fail '#option		TMPFS' 'option		TMPFS'
          substituteInPlace "$BSDSRCDIR/sys/arch/amd64/conf/Makefile.amd64" \
            --replace-fail 'CMACHFLAGS+=	-fret-clean' ""
        '';
      });
      syslogc = openbsdFinal.callPackage ../pkgs/openbsd/syslogc.nix { };
      syslogd = openbsdPrev.syslogd.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace "$BSDSRCDIR/usr.sbin/syslogd/privsep.c" \
            --replace-fail '"/usr/sbin/syslogd"' "\"$out/bin/syslogd\""
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
