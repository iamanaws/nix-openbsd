{ pkgs }:
{
  workflow-tools = {
    buildSystem = "stdenv, Make, pkg-config, Git, Perl and Python APIs";
    package = pkgs.stdenv.mkDerivation {
      pname = "sandbox-tool-workflows";
      version = "1";
      src = ./workflows/tools;
      strictDeps = true;
      nativeBuildInputs = with pkgs; [
        gnumake
        pkg-config
        gitMinimal
        perl
        python3
      ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        bash tools.sh
        runHook postBuild
      '';
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        python3 runtime.py
        runHook postCheck
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share"
        cp answer "$out/bin/answer"
        cp results.json "$out/share/workflows.json"
        runHook postInstall
      '';
    };
  };
  workflow-autotools = {
    buildSystem = "Autoconf, Automake and Libtool";
    package = pkgs.stdenv.mkDerivation {
      pname = "sandbox-autotools-workflow";
      version = "1";
      src = ./workflows/autotools;
      nativeBuildInputs = [ pkgs.autoreconfHook ];
      doCheck = true;
      enableParallelBuilding = true;
    };
  };
  workflow-cmake = {
    buildSystem = "CMake, Ninja and CTest";
    package = pkgs.stdenv.mkDerivation {
      pname = "sandbox-cmake-workflow";
      version = "1";
      src = ./workflows/cmake;
      nativeBuildInputs = with pkgs; [
        cmake
        ninja
      ];
      doCheck = true;
    };
  };
  workflow-meson = {
    buildSystem = "Meson, Ninja and pkg-config";
    package = pkgs.stdenv.mkDerivation {
      pname = "sandbox-meson-workflow";
      version = "1";
      src = ./workflows/meson;
      nativeBuildInputs = with pkgs; [
        meson
        ninja
        pkg-config
      ];
      doCheck = true;
    };
  };
  workflow-python = {
    buildSystem = "PEP 517 wheel with a C extension";
    package = pkgs.python3Packages.buildPythonPackage {
      pname = "sandbox-python-workflow";
      version = "1";
      src = ./workflows/python;
      pyproject = true;
      build-system = [ pkgs.python3Packages.setuptools ];
      pythonImportsCheck = [ "sandbox_probe" ];
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        PYTHONPATH="$(echo build/lib.*)" ${pkgs.python3.interpreter} tests.py
        runHook postCheck
      '';
    };
  };
}
