import os
from pathlib import Path
import pytest
from zyren_train.worker import Worker

ROOT = Path(__file__).resolve().parents[3]

@pytest.fixture
def worker_command():
    executable = os.environ.get('ZYREN_WORKER_EXE')
    if not executable:
        pytest.skip('requires a prepared native Dart worker; coordinate native hooks first')
    return [str(Path(executable).resolve())]

@pytest.fixture
def worker(worker_command):
    instance = Worker(worker_command, cwd=ROOT / 'examples/game_lab/training_worker', run_id='test-run')
    try:
        yield instance
    finally:
        instance.close()
