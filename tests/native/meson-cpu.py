"""Check Meson's native CPU detection on the supported OpenBSD/amd64 guest."""
import platform

from mesonbuild.envconfig import detect_cpu, detect_cpu_family

assert platform.system() == "OpenBSD"
assert platform.machine().lower() in {"amd64", "x86_64"}
print(f"machine={platform.machine()!r}, processor={platform.processor()!r}")
family, cpu = detect_cpu_family({}), detect_cpu({})
print(f"Meson CPU family={family!r}, CPU={cpu!r}")
assert (family, cpu) == ("x86_64", "x86_64"), "Meson detected the CPU model instead of its architecture"
print("MESON_CPU_PASS")
