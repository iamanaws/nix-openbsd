"""Temporarily disable PF in disposable native test VMs."""
from contextlib import contextmanager
import subprocess


@contextmanager
def disabled(binary):
    def command(*args):
        return subprocess.run([str(binary), *map(str, args)], capture_output=True,
                              text=True, timeout=30, check=True)

    def enabled():
        return 'Status: Enabled' in command('-si').stdout

    original = enabled()
    try:
        if original:
            command('-d')
        assert not enabled()
        yield command
    finally:
        if enabled() != original:
            command('-e' if original else '-d')
