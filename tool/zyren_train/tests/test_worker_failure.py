import sys
import numpy as np
import pytest
from zyren_train.gym_env import ZyrenEnv
from zyren_train.worker import Worker, WorkerFailed
from zyren_train.protocol import ProtocolError


def test_killed_worker_is_failed_truncation_never_success(worker):
    env = ZyrenEnv(worker)
    _, before = env.reset(seed=7)
    worker.process.kill()
    worker.process.wait(timeout=3)
    _, reward, terminated, truncated, info = env.step(np.zeros(2, dtype=np.float32))
    assert truncated and not terminated and reward == 0
    assert info['worker_failed'] and not info['success']
    assert info['episode_id'] == before['episode_id']
    env.close()


def test_truncated_process_output_fails_hello(tmp_path):
    with pytest.raises(WorkerFailed):
        Worker([sys.executable, '-c', "import sys; sys.stdout.buffer.write(b'\\x01'); sys.stdout.flush()"], cwd=tmp_path, timeout=1)


def test_version_negotiation_cannot_raise_limits(worker):
    assert worker.max_header <= 65536 and worker.max_message <= 16 * 1024 * 1024
    with pytest.raises(ProtocolError):
        worker.call('hello', environment_id='supervisor', episode_id='none', actor_ids=[], tick=0)


def test_unread_large_write_obeys_process_timeout(tmp_path):
    program = """
import sys, time
from zyren_train.protocol import read_frame, Frame, encode
frame = read_frame(sys.stdin.buffer)
h = dict(frame.header, ok=True, max_header=65536, max_message=16777216)
sys.stdout.buffer.write(encode(Frame(h, b''))); sys.stdout.flush()
time.sleep(60)
"""
    instance = Worker([sys.executable, '-c', program], cwd=tmp_path, timeout=.2)
    try:
        with pytest.raises(WorkerFailed):
            instance.call('step', environment_id='env', episode_id='ep', actor_ids=['actor'], tick=0,
                          arrays={'action.actor': np.zeros(1024 * 1024, dtype=np.float32)})
    finally:
        instance.close()


def test_out_of_order_responses_keep_request_identity(tmp_path):
    from concurrent.futures import ThreadPoolExecutor
    program = """
import sys
from zyren_train.protocol import read_frame, Frame, encode
hello = read_frame(sys.stdin.buffer)
sys.stdout.buffer.write(encode(Frame(dict(hello.header, ok=True, max_header=65536, max_message=16777216), b''))); sys.stdout.flush()
requests = [read_frame(sys.stdin.buffer), read_frame(sys.stdin.buffer)]
for request in reversed(requests):
    header = dict(request.header, ok=True, tick=request.header['tick'] + 1, payload_bytes=0, tensors=[])
    sys.stdout.buffer.write(encode(Frame(header, b''))); sys.stdout.flush()
sys.stdin.buffer.read()
"""
    instance = Worker([sys.executable, '-c', program], cwd=tmp_path, timeout=2)
    try:
        with ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(instance.call, 'step', environment_id=key, episode_id='ep', actor_ids=[], tick=0)
                       for key in ('a', 'b')]
            assert [f.result().header['environment_id'] for f in futures] == ['a', 'b']
    finally:
        instance.close()


def test_eof_shutdown_disposes_native_environments_before_exit(worker):
    env = ZyrenEnv(worker)
    env.reset(seed=7)
    worker.close()
    assert worker.process.returncode == 0
