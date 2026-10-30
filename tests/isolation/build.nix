{
  fixtures,
  nonce,
  kind ? "checks",
  outside ? "",
  undeclared ? "",
  ports ? "[]",
  url ? "",
  hash ? "",
  noChroot ? false,
  requiredFeatures ? [ ],
  probeSpec ? "{}",
}:
let
  inputs = builtins.storePath fixtures;
  fixed = builtins.elem kind [
    "fetch"
    "builtin-fetch"
  ];
in
derivation (
  {
    name = "openbsd-isolation-${kind}-${nonce}";
    system = "x86_64-openbsd";
    builder =
      if kind == "builtin-fetch" then
        "builtin:fetchurl"
      else if
        builtins.elem kind [
          "fd-audit"
          "limits"
        ]
      then
        "${inputs}/probe/bin/exec-probe"
      else
        "${inputs}/bash/bin/bash";
    args =
      if kind == "builtin-fetch" then
        [ ]
      else if
        builtins.elem kind [
          "fd-audit"
          "limits"
        ]
      then
        [ kind ]
      else
        [
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
              else if kind == "exec-policies" then
                ''
                  ${inputs}/python3/bin/python3 -B ${inputs}/tests/pledge.py
                ''
              else if kind == "control" then
                ''
                  ${inputs}/coreutils/bin/cat "$outside" > "$out"
                  ${inputs}/coreutils/bin/id -u >> "$out"
                  ${inputs}/coreutils/bin/id -g >> "$out"
                ''
              else
                ''
                  ${inputs}/python3/bin/python3 -B ${inputs}/tests/builder.py
                ''
            )
          )
        ];
    inherit
      fixtures
      kind
      outside
      undeclared
      ports
      url
      probeSpec
      ;
    __noChroot = noChroot;
    requiredSystemFeatures = requiredFeatures;
  }
  // (
    if fixed then
      {
        outputHashAlgo = "sha256";
        outputHashMode = "flat";
        outputHash = hash;
      }
    else
      { }
  )
)
