{ pkgs, source }:
pkgs.runCommand "openbsd-local-tests"
  {
    nativeBuildInputs = with pkgs; [
      python3
      bash
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      jq
      stdenv.cc
    ];
  }
  ''
    export HOME="$TMPDIR/home" PYTHONDONTWRITEBYTECODE=1
    mkdir -p "$HOME"
    cd ${source}
    python3 -B -m unittest discover -s tests -p 'test_*.py'
    python3 -B -m unittest discover -s tests/generations -p 'test_*.py'
    python3 -B -m unittest discover -s vm -p 'test_*.py'
    python3 -B tests/native/test-runner.py
    python3 -B tests/isolation/snapshot-copy.py --cxx "$CXX"
    touch "$out"
  ''
