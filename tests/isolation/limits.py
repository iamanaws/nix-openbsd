"""Exhaust limits installed by Nix, without lowering them in the payload."""
import errno
import json
import mmap
import os
import resource
import signal
import subprocess


def inspect_limits(fixtures, kind, metadata, expected):
    resources = {'nproc': resource.RLIMIT_NPROC, 'nofile': resource.RLIMIT_NOFILE,
                 'data': resource.RLIMIT_DATA}
    limits = {name: list(resource.getrlimit(number)) for name, number in resources.items()}
    assert limits == expected, (limits, expected)
    probe = fixtures / 'probe/bin/exec-probe'
    assert json.loads(subprocess.check_output([probe, 'limit-state'])) == limits
    subprocess.run([probe, 'limits-raise'], check=True)
    metadata['limits'] = limits
    children, descriptors = [], []
    hold = kind == 'limit-hold'
    try:
        if kind in ['limit-processes', 'limit-hold']:
            # Exercise the hard ceiling: raising the soft value within it is allowed.
            maximum = limits['nproc'][1]
            assert maximum <= 32
            resource.setrlimit(resource.RLIMIT_NPROC, (maximum, maximum))
            if hold:
                metadata['ipc'] = json.loads(subprocess.check_output([probe, 'ipc-create']))
            while True:
                try:
                    child = os.fork()
                except OSError as error:
                    assert error.errno == errno.EAGAIN, error
                    break
                if child == 0:
                    os.setsid()
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    for descriptor in [0, 1, 2]:
                        os.close(descriptor)
                    while True:
                        signal.pause()
                children.append(child)
                assert len(children) <= maximum
            assert children
            metadata['children'] = children
            metadata['processExhaustion'] = 'EAGAIN'
        if kind in ['limit-fds', 'limit-hold']:
            maximum = limits['nofile'][1]
            assert maximum <= 128
            resource.setrlimit(resource.RLIMIT_NOFILE, (maximum, maximum))
            while True:
                try:
                    descriptors.append(os.open('/dev/null', os.O_RDONLY))
                except OSError as error:
                    assert error.errno == errno.EMFILE, error
                    break
                assert len(descriptors) <= maximum
            assert descriptors
            metadata['descriptorExhaustion'] = 'EMFILE'
            metadata['openedDescriptors'] = len(descriptors)
        if kind == 'limit-data':
            maximum = limits['data'][1]
            assert maximum <= 2 * 1024 * 1024 * 1024
            resource.setrlimit(resource.RLIMIT_DATA, (maximum, maximum))
            with mmap.mmap(-1, 1024 * 1024, flags=mmap.MAP_PRIVATE | mmap.MAP_ANON) as control:
                control[0] = 42
            try:
                mapping = mmap.mmap(-1, maximum, flags=mmap.MAP_PRIVATE | mmap.MAP_ANON)
            except OSError as error:
                assert error.errno == errno.ENOMEM, error
            else:
                mapping.close()
                raise AssertionError('anonymous mmap exceeded the data limit')
            metadata['dataExhaustion'] = 'ENOMEM'
        if hold:
            print('SANDBOX_METADATA ' + json.dumps(metadata), flush=True)
            while True:
                signal.pause()
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
        for child in children:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for child in children:
            os.waitpid(child, 0)
