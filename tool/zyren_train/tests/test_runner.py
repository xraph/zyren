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
