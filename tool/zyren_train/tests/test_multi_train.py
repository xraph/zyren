import copy
import hashlib
import json
import os
from pathlib import Path
import pytest
from zyren_train.multi_train import MultiTrainingConfig, train_multi


def config(command,family,steps=32):
    from zyren_train.train import worker_native_hashes
    import subprocess
    specs=json.loads(subprocess.check_output([command,'--scenario-specs'],text=True))
    spec=next(s for s in specs if s['id']==family)
    return MultiTrainingConfig.from_dict({'schema_version':2,'task':family,'history_every_updates':1,'history_versions':4,
        'training':{'schema_version':1,'policy_distribution':'masked-categorical-v1','seed':7,'device':'cpu','algorithm':'recurrent_ppo',
            'network':{'hidden_sizes':[128,128],'lstm_hidden_size':128},
            'optimizer':{'learning_rate':.001,'epochs':1,'gamma':.99,'gae_lambda':.95,'clip':.2,'entropy':.01,'value':.5,'max_grad_norm':.5},
            'rollout':{'environments':1,'steps':8},'total_steps':steps,'checkpoint_every_steps':8,'evaluation_every_steps':1000,
            'scenarios':[spec],'curriculum':[{'name':'occlusion','scenario':family,'after_steps':0}],
            'rewards':{'task.progress':1},'datasets':{'train':[],'validation':[],'test':[]},'bc_epochs':0,
            'worker_sha256':hashlib.sha256(Path(command).read_bytes()).hexdigest(),'worker_native_sha256':worker_native_hashes(command)}})


def test_real_joint_training_changes_weights_and_resumes_at_a_reset_boundary(tmp_path):
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly frozen multi worker')
    cfg=config(command,'cooperative-search');run=tmp_path/'run'
    first=train_multi(cfg,run,[command],cwd=Path(__file__).resolve().parents[3],stop_after_updates=1)
    assert first['state']=='cancelled' and first['actor_transitions']==16 and first['workers_closed']
    last=train_multi(cfg,run,[command],cwd=Path(__file__).resolve().parents[3],resume=True)
    assert last['state']=='completed' and last['steps']==32 and last['actor_transitions']==64
    assert last['worker_exit_codes']==[0] and last['quality'] is None
    receipts=[json.loads(line) for line in (run/'receipts.jsonl').read_text().splitlines()]
    ticks=[r['native_completed_tick'] for r in receipts if r.get('phase')=='joint-ppo']
    assert ticks==[9,9,17,25]


def test_multi_config_rejects_test_curriculum_and_unbounded_history(tmp_path):
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly frozen multi worker')
    data=config(command,'competitive-pursuit').data
    for field,value in [('history_versions',33),('history_every_updates',0)]:
        forged=copy.deepcopy(data);forged[field]=value
        with pytest.raises(ValueError):MultiTrainingConfig.from_dict(forged)
    data['training']['scenarios'][0]['partition']='test'
    with pytest.raises(ValueError):MultiTrainingConfig.from_dict(data)
