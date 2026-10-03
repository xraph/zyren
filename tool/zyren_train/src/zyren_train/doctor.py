"""Read local toolchain qualification without downloading models or starting jobs."""
from importlib import metadata
from pathlib import Path
import platform
import shutil


def doctor(worker=None):
    packages = {}
    for name in ('numpy', 'torch', 'onnx', 'onnxruntime', 'gymnasium'):
        try:
            packages[name] = metadata.version(name)
        except metadata.PackageNotFoundError:
            packages[name] = None
    executable = Path(worker).resolve() if worker else None
    return {'schema_version': 1, 'platform': platform.platform(), 'python': platform.python_version(),
            'packages': packages, 'uv': shutil.which('uv'), 'fvm': shutil.which('fvm'),
            'worker': str(executable) if executable else None,
            'worker_available': bool(executable and executable.is_file()),
            'native_worker_verified': False, 'gpu_qualified': None,
            'model_downloads': False}
