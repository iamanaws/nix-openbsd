"""Check ABI calls, a compiled extension and libffi callbacks."""
import importlib.util

from cffi import FFI

abi = FFI()
abi.cdef("size_t strlen(const char *);")
assert abi.dlopen(None).strlen(b"OpenBSD") == 7

builder = FFI()
builder.cdef('''
    extern "Python" int twice(int);
    int call_callback(int (*callback)(int), int value);
''')
builder.set_source("_native_cffi_test", """
int call_callback(int (*callback)(int), int value) {
    return callback(value) + 1;
}
""")
spec = importlib.util.spec_from_file_location(
    "_native_cffi_test", builder.compile(verbose=True)
)
extension = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extension)
ffi, lib = extension.ffi, extension.lib

@ffi.def_extern()
def twice(value):
    return value * 2

assert lib.call_callback(lib.twice, 21) == 43
print("PASS CFFI: libc ABI, compiled extension and extern Python callback")
