from setuptools import Extension, setup

setup(name='sandbox-python-workflow', version='1',
      ext_modules=[Extension('sandbox_probe', ['probe.c'])])
