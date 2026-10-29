"""Measure shared kernel state without treating it as isolated."""
import json
import socket
import subprocess


def inspect_boundaries(fixtures, metadata, spec):
    probe = fixtures / 'probe/bin/exec-probe'
    subprocess.run([probe, 'process-visible', str(spec['hostPid'])], check=True)
    subprocess.run([probe, 'ipc-denied', *map(str, spec['private'])], check=True)
    subprocess.run([probe, 'ipc-denied', *map(str, spec['group'])], check=True)
    subprocess.run([probe, 'ipc-access', *map(str, spec['public'])], check=True)
    metadata['ipc'] = json.loads(subprocess.check_output([probe, 'ipc-create']))
    metadata['boundaries'] = {'hostProcessVisible': True,
                              'crossUserSignalsDenied': True, 'privateIpcDenied': True,
                              'publicIpcAccessible': True, 'sharedGroupIpcDenied': True}
    listeners = []
    try:
        for family, address in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
            listener = socket.socket(family, socket.SOCK_STREAM)
            listeners.append(listener)
            listener.bind((address, 0))
            listener.listen(1)
            listener.settimeout(60)
        metadata['listenerPorts'] = [listener.getsockname()[1] for listener in listeners]
        print('SANDBOX_METADATA ' + json.dumps(metadata), flush=True)
        for listener in listeners:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(5)
                token = spec['token'].encode()
                assert connection.recv(128) == token
                connection.sendall(token)
    finally:
        for listener in listeners:
            listener.close()
