{
  pkgs,
  disallowedRequisites,
  python,
}:
pkgs.stdenv.mkDerivation {
  name = "openbsd-package-checks";
  src = ./.;
  strictDeps = true;
  inherit disallowedRequisites;

  nativeBuildInputs = with pkgs; [
    cmake
    pkg-config
    sqlite
    tmux
    python
  ];
  buildInputs = with pkgs; [
    sqlite
    libevent
    fmt
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    test "$(uname -s)" = OpenBSD
    test "$EUID" -ne 0
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ./sqlite-consumer
    ./event-consumer
    ./fmt-consumer
    timeout 30 bash ../tmux.sh
    python3 ../cffi-consumer.py
    runHook postCheck
  '';

  installPhase = ''
    mkdir -p "$out"
    printf '%s\n' "$EUID" > "$out/build-uid"
    printf '%s\n' ${
      pkgs.lib.escapeShellArgs (
        map toString [
          pkgs.sqlite
          pkgs.tmux
          pkgs.libevent
          pkgs.fmt
          python
        ]
      )
    } > "$out/runtime-roots"
    touch "$out/passed"
  '';
}
