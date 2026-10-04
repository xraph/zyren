import sys
import pytest
from zyren_train.runner import LocalProcessRunner,RunnerBudget,RemoteRunner


def test_local_process_uses_explicit_budget_and_argument_array(tmp_path):
    runner=LocalProcessRunner(RunnerBudget(cpu_threads=1,camera_workers=1,memory_mib=4096,disk_mib=128))
    result=runner.run([sys.executable,'-c','import os;print(os.environ["OMP_NUM_THREADS"])'],cwd=tmp_path,output=tmp_path/'output',timeout=5)
    assert result['exit_code']==0 and result['stdout']=='1\n'
    assert result['resource_budget']['cpu_threads']==1 and result['memory_qualification'] is None
    with pytest.raises(ValueError):RunnerBudget(cpu_threads=0,camera_workers=1,memory_mib=4096,disk_mib=128)
    with pytest.raises(ValueError):runner.run('echo unsafe',cwd=tmp_path,output=tmp_path/'output2',timeout=5)


def test_timeout_and_output_budget_drain_child(tmp_path):
    runner=LocalProcessRunner(RunnerBudget(cpu_threads=1,camera_workers=1,memory_mib=4096,disk_mib=128))
    timeout=runner.run([sys.executable,'-c','import time;time.sleep(10)'],cwd=tmp_path,output=tmp_path/'timeout',timeout=.1)
    assert timeout['state']=='cancelled' and timeout['live_processes']==0
    large=runner.run([sys.executable,'-c','print("x"*1000000)'],cwd=tmp_path,output=tmp_path/'large',timeout=5)
    assert large['state']=='failed' and large['reason']=='output-budget' and len(large['stdout'].encode())<=65536 and large['live_processes']==0


def test_remote_cannot_execute_without_explicit_configuration():
    with pytest.raises(ValueError,match='configured'):RemoteRunner(None)
    with pytest.raises(ValueError,match='HTTPS'):RemoteRunner({'base_url':'http://example.com','authorization':'secret'})


def test_disk_budget_checks_fast_completed_process(tmp_path):
    output=tmp_path/'disk';output.mkdir()
    runner=LocalProcessRunner(RunnerBudget(cpu_threads=1,camera_workers=1,memory_mib=4096,disk_mib=128))
    result=runner.run([sys.executable,'-c',f'from pathlib import Path;p=Path({str(output / "oversize")!r});p.open("wb").truncate(129*1048576)'],cwd=tmp_path,output=output,timeout=5)
    assert result['state']=='failed' and result['reason']=='disk-budget'


def test_shared_backend_runs_actual_pinned_trainer_and_checks_receipts(worker_command,tmp_path):
    from training_support import configuration,ROOT
    from zyren_train.runner import LocalTrainingRunner,RunnerBackend
    config=configuration(worker_command,steps=8)
    budget=RunnerBudget(cpu_threads=1,camera_workers=0,memory_mib=4096,disk_mib=128)
    runner=LocalTrainingRunner(worker=worker_command[0],cwd=ROOT/'examples/game_lab/training_worker',output=tmp_path/'jobs',timeout=30)
    assert isinstance(runner,RunnerBackend)
    result=runner.submit(config=config,worker_sha256=config.data['worker_sha256'],budget=budget,job_id='native-short')
    assert result['state']=='completed' and result['exit_code']==0 and result['live_processes']==0
    assert result['config_hash']==config.hash and len(result['trainer_receipt_hash'])==64 and len(result['checkpoint_sha256'])==64
    with pytest.raises(ValueError):runner.submit(config=config,worker_sha256='0'*64,budget=budget,job_id='wrong-pin')
    assert not (tmp_path/'jobs/wrong-pin').exists()
    with pytest.raises(ValueError,match='resume|Resume|cannot resume'):runner.submit(config=config,worker_sha256=config.data['worker_sha256'],budget=budget,job_id='native-short',resume=True)
