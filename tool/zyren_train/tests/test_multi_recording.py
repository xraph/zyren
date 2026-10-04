import torch
import pytest
from zyren_train.multi_recording import multi_training_sequences
from zyren_train.demonstration import DemonstrationRecorder
from zyren_train.dataset import DatasetPartition
from zyren_train.policies.structured import StructuredPolicy
from zyren_train.scenario import ScenarioSpec
from test_multi_evaluation import plan_value


def source(tmp_path,learners):
    value=plan_value()['cases'][0]['scenario'];value['partition']='train'
    spec=ScenarioSpec.from_dict(value);path=tmp_path/'source'
    recorder=DemonstrationRecorder(path,scenario=spec,session_id='source',run_id='run',environment_id='env',
        source='scripted',model_hash='permitted-teacher-v2',recording_settings={'learner_actors':learners})
    for tick in range(3):
        recorder.append({'episode_id':'episode','tick':tick+1,'actor_generations':{'a':1,'b':1},
            'observations':{'a':[1.]*36,'b':[-1.]*36},'proposed_actions':{'a':[2,2,4,1,0,0],'b':[2,2,0,1,0,0]},
            'applied_actions':{'a':[2,2,4,1,0,0],'b':[2,2,0,1,0,0]},
            'fallback':{'a':False,'b':False},'delay_ticks':{'a':0,'b':0},'reward_terms':{'progress':0.},
            'terminated':tick==2,'truncated':False,
            'legality':{a:[[True]*n for n in [5,5,5,3,2,2]] for a in ['a','b']}})
    recorder.finalize();return DatasetPartition.from_recordings('train',[path])


def test_joint_sources_split_private_actor_sequences_without_stationary_opponent_labels(tmp_path):
    partition=source(tmp_path,['a'])
    policy=StructuredPolicy(36,{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},fallback=[2,2,2,1,0,0])
    rows=list(multi_training_sequences(partition,policy))
    assert len(rows)==1 and rows[0][0].shape==(3,1,36)
    assert torch.equal(rows[0][1][:,0,2],torch.tensor([4,4,4]))
    assert rows[0][2].sum()==1
    with pytest.raises(ValueError):list(multi_training_sequences(DatasetPartition('validation',()),policy))


def test_joint_actor_source_yields_two_independent_full_memory_graphs(tmp_path):
    policy=StructuredPolicy(36,{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},fallback=[2,2,2,1,0,0])
    rows=list(multi_training_sequences(source(tmp_path,['a','b']),policy))
    assert len(rows)==2 and rows[0][0][0,0,0]==1 and rows[1][0][0,0,0]==-1


def test_real_frozen_joint_teacher_recording_replays_both_native_controllers(tmp_path):
    import os
    from pathlib import Path
    from zyren_train.worker import Worker
    from zyren_train.multi_recording import record_multi_teacher,replay_multi_recording
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly frozen multi worker')
    worker=Worker([command],cwd=Path(__file__).resolve().parents[3],run_id='multi-record-test',timeout=60)
    try:
        path=tmp_path/'native'
        receipt=record_multi_teacher(worker,'cooperative-search',path,seed=7)
        replay=replay_multi_recording(worker,path)
        assert receipt['results']=={'a':'win','b':'win'} and receipt['collision'] is False
        assert replay['steps']==receipt['steps'] and replay['native_backend']=='rapier'
    finally:worker.close()
    assert worker.process.returncode==0
