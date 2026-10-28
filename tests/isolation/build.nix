{
  fixtures,
  nonce,
  kind ? "control",
  outside ? "",
  url ? "",
  hash ? "",
}:
let
  inputs = builtins.storePath fixtures;
in
derivation (
  {
    name = "openbsd-isolation-${kind}-${nonce}";
    system = "x86_64-openbsd";
    builder = "${inputs}/bash/bin/bash";
    args = [
      "-euc"
      (
        ''
          test "$EUID" -ne 0
          printf 'ISOLATION_BUILDER_STARTED\n' >&2
        ''
        + (
          if kind == "consumers" then
            ''
              ${inputs}/bash/bin/bash ${inputs}/tests/consumers.sh ${inputs} "$out"
            ''
          else if kind == "fetch" then
            ''
              ${inputs}/curl/bin/curl --noproxy '*' --connect-timeout 3 --max-time 10 -fsS "$url" -o "$out"
            ''
          else
            ''
              ${inputs}/coreutils/bin/cat "$outside" > "$out"
              ${inputs}/coreutils/bin/id -u >> "$out"
            ''
        )
      )
    ];
    inherit outside url;
  }
  // (
    if kind == "fetch" then
      {
        outputHashAlgo = "sha256";
        outputHashMode = "flat";
        outputHash = hash;
      }
    else
      { }
  )
)
