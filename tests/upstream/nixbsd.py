"""Check the proposed NixBSD patches against the project's pinned inputs."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
flake = f'builtins.getFlake {json.dumps("path:" + str(root))}'


def evaluate(expression):
    return json.loads(subprocess.check_output(
        ["nix", "eval", "--impure", "--json", "--expr", expression], text=True
    ))


inputs = evaluate(f"let f = {flake}; in {{ "
                  "nixbsd = f.inputs.nixbsd.outPath; "
                  "nixpkgs = f.inputs.nixbsd.inputs.nixpkgs.outPath; }")
source = Path(inputs["nixbsd"])
fixture = root / "tests/upstream/nixbsd.nix"
patches = root / "upstream/nixbsd"


def inspect(path):
    return evaluate(f"import {fixture} {{ "
                    f"nixbsdSource = {json.dumps(str(path))}; "
                    f"nixpkgsSource = {json.dumps(inputs['nixpkgs'])}; }}")


def check_versions(data, work):
    template = (source / "modules/installer/tools/nixos-version.sh").read_text()
    for platform, cases in data["versions"].items():
        for case, replacements in cases.items():
            assert "configurationRevision" in replacements, "Missing shell substitution"
            script = template
            for key, value in replacements.items():
                if value is not None:
                    script = script.replace(f"@{key}@", str(value))
            target = work / f"{platform}-{case}.sh"
            target.write_text(script)
            result = subprocess.run(
                ["bash", str(target), "--configuration-revision"],
                capture_output=True, text=True,
            )
            if case == "known":
                assert result.returncode == 0 and result.stdout == "abc123\n"
            else:
                assert result.returncode == 1 and "revision is unknown" in result.stderr
            metadata = json.loads(subprocess.check_output(
                ["bash", str(target), "--json"], text=True
            ))
            assert metadata.get("configurationRevision") == replacements["configurationRevision"]


def check_start(data, work):
    assert data["hooks"]["plain"] is None
    script = '''
daemon=/test/daemon
daemon_flags=
rc_exec() { printf 'exec\n' >> "$TRACE"; return "$START_STATUS"; }
rc_start() {
''' + data["hooks"]["post"] + "\n}\nrc_start\n"
    for start, post, expected, trace in [
        (42, 0, 42, "exec\n"),
        (0, 0, 0, "exec\npost\n"),
        (0, 17, 17, "exec\npost\n"),
    ]:
        output = work / "trace"
        output.write_text("")
        result = subprocess.run(["bash", "-c", script], env=os.environ | {
            "TRACE": str(output), "START_STATUS": str(start), "POST_STATUS": str(post),
        })
        assert result.returncode == expected, (start, post, result.returncode)
        assert output.read_text() == trace


def check_directory(path, work):
    text = (path / "modules/system/boot/init/openbsd-rc.nix").read_text()
    command = re.search(r"^\s*(mkdir -p /var/run[^\n]*)$", text, re.MULTILINE).group(1)
    run = work / "run"
    command = command.replace("/var/run", str(run))
    subprocess.run(["bash", "-c", command], check=True)
    database = run / "dev.db"
    assert not database.exists(), "rc created dev.db as a directory"
    database.write_text("database probe")
    subprocess.run(["bash", "-c", command], check=True)
    assert database.read_text() == "database probe"


with tempfile.TemporaryDirectory(prefix="nixbsd-patch-check-") as directory:
    work = Path(directory)
    patched = work / "source"
    shutil.copytree(source / "modules/installer/tools", patched / "modules/installer/tools")
    for path in (patched / "modules/installer/tools").rglob("*"):
        path.chmod(0o755 if path.is_dir() else 0o644)
    (patched / "modules/installer/tools").chmod(0o755)
    for name in ["openbsd-rc.nix", "portable/openbsd.nix"]:
        target = patched / "modules/system/boot/init" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / "modules/system/boot/init" / name, target)
    for patch in sorted(patches.glob("*.patch")):
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=patched, check=True)
        subprocess.run(["git", "apply", str(patch)], cwd=patched, check=True)
    original = inspect(source)
    fixed = inspect(patched)
    for check, before, after in [
        (check_versions, original, fixed),
        (check_start, original, fixed),
        (check_directory, source, patched),
    ]:
        for label, value, should_pass in [("original", before, False), ("patched", after, True)]:
            case = work / (check.__name__ + "-" + label)
            case.mkdir()
            try:
                check(value, case)
            except AssertionError:
                if should_pass:
                    raise
            else:
                assert should_pass, f"{check.__name__}: original no longer reproduces the bug"
        print(f"PASS {check.__name__}: original fails, patched passes")
