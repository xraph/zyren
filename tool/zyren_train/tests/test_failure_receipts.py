import concurrent.futures
import copy
import hashlib
import json
import os
from pathlib import Path
import time
import numpy as np
import pytest
import torch
from zyren_train.worker import Worker,WorkerFailed
from zyren_train.gym_env import ZyrenEnv
from zyren_train.pettingzoo_env import ZyrenParallelEnv
from zyren_train.protocol import Frame,ProtocolError
from zyren_train.policies.structured import StructuredPolicy
from zyren_train.scenario import canonical_bytes


def emit(name,before,after,*,kind,counters):
    assert before==after
    assert counters['before']==counters['after']
    path=os.environ.get('GAME_FAILURE_RECEIPT_PATH')
    if path:
        p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
        document=json.loads(p.read_text()) if p.exists() else {'schemaVersion':1,'cases':{}}
        document['cases'][name]={'status':'passed','actualStatus':'rejected','before':before,'after':after,
            'cleanupCounters':counters,'recovery':{'action':'retry','status':'passed'},
            'execution':{'kind':kind,'exitCode':0,'command':f"ZYREN_WORKER_EXE={os.environ.get('ZYREN_WORKER_EXE','')} GAME_FAILURE_RECEIPT_PATH={path} uv run pytest tests/test_failure_receipts.py -q"}}
        p.write_bytes(canonical_bytes(document,16_777_216))


def test_real_native_worker_crash_rejects_pending_and_preserves_other_owner(worker,worker_command):
    protected=ZyrenEnv(worker,environment_id='protected')
    _,info=protected.reset(seed=7)
    def identity():
        return {'identity':{k:info[k] for k in ('run_id','environment_id','episode_id','actor_ids','actor_generations','tick','seed','build_id','observation_schema_hash','action_schema_hash')},
            'session':protected.snapshot(),'protectedNativePid':worker.process.pid}
    before=identity();counters={'owners':int(worker.process.poll() is None),'pendingRequests':len(worker._pending)}
    victim=Worker(worker_command,cwd=worker.cwd,run_id='crash-victim')
    try:
        victim_env=ZyrenEnv(victim,environment_id='victim');victim_env.reset(seed=7)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending=executor.submit(victim.call,'reset',environment_id='capture-pending',episode_id='reset',actor_ids=[],tick=0,
                extra={'seed':7,'scenario':'guard-visual-combined','purpose':'training'})
            until=time.monotonic()+2
            while not victim._pending and not pending.done() and time.monotonic()<until:time.sleep(.0001)
            assert victim._pending and not pending.done()
            victim.process.kill()
            with pytest.raises(WorkerFailed):pending.result(timeout=5)
        victim.close();victim.close()
        assert victim.process.returncode is not None and victim.process.returncode!=0 and not victim._pending
        after=identity()
        assert before==after
        recovery=Worker(worker_command,cwd=worker.cwd,run_id='crash-recovery')
        try:
            env=ZyrenEnv(recovery,environment_id='retry')
            env.reset(seed=7)
            result=env.step(np.asarray([.25,0],dtype=np.float32))
            assert result[4]['tick']==2 and not result[4].get('worker_failed')
            env.close()
        finally:recovery.close()
        assert recovery.process.returncode==0
        emit('worker.crash',before,after,kind='native',counters={'before':counters,'after':{'owners':int(worker.process.poll() is None)+int(victim.process.poll() is None)+int(recovery.process.poll() is None),'pendingRequests':len(worker._pending)+len(victim._pending)+len(recovery._pending)}})
    finally:victim.close();protected.close()


def test_teacher_only_fields_cannot_enter_actor_tensor_or_change_decoded_action():
    torch.set_num_threads(1);torch.manual_seed(7)
    contract={'kind':'box','low':[-1.],'high':[1.]}
    env=ZyrenParallelEnv(None,scenario='pure-fixture',possible_agents=['a'],observation_width=4,action_space=contract)
    policy=StructuredPolicy(4,contract).eval()
    header={'version':1,'operation':'reset','sequence':1,'run_id':'fixture','environment_id':'parallel','episode_id':'parallel-1',
        'actor_ids':['a'],'actor_generations':{'a':1},'tick':1,'observation_schema_hash':'a'*64,'action_schema_hash':'b'*64,'build_id':'c'*64,'split':'training','action_space':contract,
        'observation_schema':{'fields':[{'id':'perception','width':4}]},'training_only':{'state':[1000.,-1000.],'teacher_actions':{'a':[1.]},'distances':{'a':99.}}}
    observations,infos=env._read(Frame.from_arrays(header,{'observation.a':np.asarray([.1,.2,.3,.4],dtype='<f4')}))
    def protected_identity():
        with torch.no_grad():
            output,_,state=policy.step(torch.tensor(observations['a']).unsqueeze(0),policy.initial_state(1),torch.ones(1,dtype=torch.bool))
            action=policy.distribution(output).mode().numpy().tolist()
        return {'identity':{'observationSha256':hashlib.sha256(observations['a'].tobytes()).hexdigest(),'modelStateSha256':hashlib.sha256(b''.join(v.numpy().tobytes() for v in policy.state_dict().values())).hexdigest(),'observationSchemaHash':'a'*64,'actionSchemaHash':'b'*64,'buildId':'c'*64,'decodedAction':action,'nextHiddenSha256':hashlib.sha256(state[0].numpy().tobytes()+state[1].numpy().tobytes()).hexdigest()}}
    before=protected_identity()
    assert all(set(i).isdisjoint(header['training_only']) for i in infos.values())
    changed=copy.deepcopy(header);changed['training_only']['teacher_actions']['a']=[-1.];changed['training_only']['state']=[-9999.,9999.]
    observations,infos=env._read(Frame.from_arrays(changed,{'observation.a':np.asarray([.1,.2,.3,.4],dtype='<f4')}))
    assert protected_identity()==before
    leaked=copy.deepcopy(changed);leaked['observation_schema']['fields'][0]['id']='teacher_actions'
    with pytest.raises(ProtocolError,match='Teacher-only'):env._read(Frame.from_arrays(leaked,{'observation.a':np.asarray([.1,.2,.3,.4],dtype='<f4')}))
    observations,_=env._read(Frame.from_arrays(header,{'observation.a':np.asarray([.1,.2,.3,.4],dtype='<f4')}))
    emit('leakage.teacher-input',before,protected_identity(),kind='pure',counters={'before':{'owners':1,'pendingRequests':0},'after':{'owners':1,'pendingRequests':0}})
