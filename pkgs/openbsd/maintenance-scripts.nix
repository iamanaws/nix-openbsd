{
  lib,
  mkDerivation,
  perl,
  oksh,
  coreutils,
  diffutils,
  gnugrep,
  gnused,
  mandoc,
  awk,
  find,
  fdisk,
  install,
  mail,
  dump,
  bioctl,
  calendar,
  ac,
  sa,
  lastcomm,
  sort,
  rcctl,
  pkg_info,
  stat,
  df,
  sysctl,
  hostname,
  domainname,
  disklabel,
  mount,
  mtree,
  fsck,
  dd,
  sync,
  su,
  getcap,
  locate,
}:
let
  runtimePath = lib.makeBinPath [
    awk
    find
    fdisk
    install
    mail
    dump
    bioctl
    calendar
    ac
    sa
    lastcomm
    sort
    locate
    rcctl
    pkg_info
    stat
    df
    sysctl
    hostname
    domainname
    disklabel
    mount
    mtree
    fsck
    dd
    sync
    su
    getcap
    coreutils
    diffutils
    gnugrep
    gnused
  ];
in
mkDerivation {
  pname = "maintenance-scripts";
  path = "libexec/security";
  extraPaths = [
    "etc/daily"
    "etc/weekly"
    "etc/monthly"
    "etc/mtree/special"
    "etc/changelist"
  ];
  noCC = true;
  dontConfigure = true;
  dontBuild = true;
  skipIncludesPhase = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/etc/mtree" "$out/libexec"
    for period in daily weekly monthly; do
      { printf 'export PATH=%s\n' "${runtimePath}:/run/current-system/sw/bin:/bin:/usr/bin";
        cat "$BSDSRCDIR/etc/$period"; } > "$out/etc/$period"
    done
    substituteInPlace "$out/etc/daily" \
      --replace-fail '/usr/libexec/security' "$out/libexec/security"
    substituteInPlace "$out/etc/weekly" \
      --replace-fail '/usr/libexec/locate.updatedb' '${locate}/libexec/locate.updatedb' \
      --replace-fail '/usr/sbin/makewhatis' '${mandoc}/bin/makewhatis'
    install -m755 "$BSDSRCDIR/libexec/security/security" "$out/libexec/security"
    substituteInPlace "$out/libexec/security" \
      --replace-fail '#!/usr/bin/perl -T' '#!${perl}/bin/perl -T' \
      --replace-fail "'/bin:/usr/bin:/sbin:/usr/sbin'" "'${runtimePath}:/run/current-system/sw/bin:/bin:/usr/bin'" \
      --replace-fail '/bin/ksh -c' '${oksh}/bin/oksh -c'
    cp "$BSDSRCDIR/etc/mtree/special" "$out/etc/mtree/special"
    cp "$BSDSRCDIR/etc/changelist" "$out/etc/changelist"
    runHook postInstall
  '';

  meta = {
    description = "OpenBSD daily, weekly, monthly and security scripts";
    platforms = lib.platforms.openbsd;
  };
}
