"""Record isolation inside a package's existing stdenv phases."""
import ctypes
import errno
import json
import os
from pathlib import Path
import pwd
import socket
import sys
import time

name, nonce, outside, ports, event = sys.argv[1:]
library = ctypes.CDLL(None, use_errno=True)
library.getrtable.restype = ctypes.c_int
domain = library.getrtable()
assert os.getuid() != 0 and os.getgroups() == []
assert pwd.getpwuid(os.getuid()).pw_name == 'nixbld'
assert domain in [201, 202, 203, 204], domain
if event == 'START':
    assert nonce and os.getcwd() == '/build'
    assert not Path(outside).exists(), 'package can see the host fixture'
    for family, address, port in zip([socket.AF_INET, socket.AF_INET6],
                                     ['127.0.0.1', '::1'], json.loads(ports)):
        with socket.socket(family, socket.SOCK_STREAM) as connection:
            connection.settimeout(1)
            try:
                connection.connect((address, port))
            except OSError as error:
                assert error.errno in [errno.ECONNREFUSED, errno.ENETUNREACH,
                                       errno.EHOSTUNREACH, errno.ETIMEDOUT], error
            else:
                raise AssertionError('package connected to a host-domain listener')
print('SANDBOX_PACKAGE_' + event + ' ' + json.dumps({
    'package': name, 'nonce': nonce, 'uid': os.getuid(), 'domain': domain,
    'time': time.monotonic(),
}), flush=True)
