"""Console access and private copies of prepared OpenBSD test disks."""
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import time


def clone_state(source, destination):
    source, destination = Path(source).resolve(), Path(destination)
    for name in ['disk.qcow2', 'efi.fd']:
        if not (source / name).is_file():
            raise ValueError(f'Missing prepared VM file: {source / name}')
    destination.mkdir(parents=True, exist_ok=False)
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2',
                    '-b', str(source / 'disk.qcow2'), str(destination / 'disk.qcow2')], check=True)
    shutil.copyfile(source / 'efi.fd', destination / 'efi.fd')
    (destination / 'efi.fd').chmod(0o600)


class Guest:
    def __init__(self, launcher, state, log, timeout=600):
        self.launcher, self.state, self.log = Path(launcher), Path(state), Path(log)
        self.timeout = timeout
        self.buffer = b''

    def __enter__(self):
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.writer = self.log.open('wb', buffering=0)
        self.reader = self.log.open('rb')
        with socket.socket() as http, socket.socket() as ssh:
            http.bind(('127.0.0.1', 0))
            ssh.bind(('127.0.0.1', 0))
            ports = {'NIX_VM_HTTP_PORT': str(http.getsockname()[1]),
                     'NIX_VM_SSH_PORT': str(ssh.getsockname()[1])}
        self.process = subprocess.Popen(
            [str(self.launcher / 'bin/run-openbsd-native-vm')], stdin=subprocess.PIPE,
            stdout=self.writer, stderr=subprocess.STDOUT,
            env=os.environ | ports | {'NIX_VM_STATE_DIR': str(self.state)},
        )
        try:
            self.expect(rb'login:')
            self.send('root')
            self.expect(rb'Password:')
            self.send('toor')
            self.expect(rb'root@')
            self.send("stty -echo; PS1=''; PS2=''; printf '\\nTEST_GUEST_READY\\n'")
            self.expect(rb'\r?\nTEST_GUEST_READY\r?\n')
            return self
        except BaseException as error:
            self.__exit__(type(error), error, error.__traceback__)
            raise

    def expect(self, pattern, timeout=None):
        deadline = time.monotonic() + (timeout or self.timeout)
        while time.monotonic() < deadline:
            self.buffer += self.reader.read()
            match = re.search(pattern, self.buffer)
            if match:
                self.buffer = self.buffer[match.end():]
                return match
            self.buffer = self.buffer[-1024 * 1024:]
            if self.process.poll() is not None:
                raise RuntimeError(f'VM exited; see {self.log}')
            time.sleep(.1)
        raise TimeoutError(f'Waiting for {pattern!r}; see {self.log}')

    def send(self, command):
        self.process.stdin.write((command + '\n').encode())
        self.process.stdin.flush()

    def run(self, command, timeout=None):
        marker = 'TEST_COMMAND_' + secrets.token_hex(8)
        self.send(command + f"; printf '\\n{marker}:%s\\n' \"$?\"")
        code = int(self.expect(rb'\r?\n' + marker.encode() + rb':([0-9]+)\r?\n', timeout).group(1))
        if code:
            raise RuntimeError(f'Guest command failed ({code}); see {self.log}')

    def __exit__(self, error, *_):
        clean = self.process.poll() == 0
        try:
            if self.process.poll() is None:
                try:
                    if error:
                        self.send('\x03')
                    self.send('shutdown -p now')
                    self.process.wait(timeout=60)
                    clean = self.process.returncode == 0
                except (BrokenPipeError, subprocess.TimeoutExpired):
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait()
        finally:
            self.process.stdin.close()
            self.reader.close()
            self.writer.close()
        if error is None and not clean:
            raise RuntimeError(f'VM did not shut down cleanly; see {self.log}')
