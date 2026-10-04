import copy
import json
import pytest
from zyren_train.multi_physical_diagnostics import PHYSICAL_CONTRACT,capture_physical_snapshot,validate_physical_pair
from test_multi_recording import source
from zyren_train.demonstration import validate_record


def snapshot(tick=1,terminal=False):
    return {'schema_version':1,'geometry':PHYSICAL_CONTRACT,'episode_id':'episode','tick':tick,
        'actor_ids':['a','b'],'actor_generations':{'a':1,'b':1},'positions':[0,.81,0,2,.81,5],
        'active':{'a':True,'b':True},'floor_surface_y':0.,'capsule_half_height':.5,'capsule_radius':.3,
        'floor_clearance':{'a':.01,'b':.01},'collision':False,'terminal':terminal,'contact_depths':None}


def record(tmp_path):
    partition=source(tmp_path,['a','b']);path,manifest=partition.recordings[0]
    row=next(manifest.records(path));row['tick']=2;row['terminated']=True
    meta=json.loads(json.dumps(manifest.to_dict()['recording']))
    meta['recording_settings']['physical_diagnostics']=PHYSICAL_CONTRACT
    return row,meta


def test_capture_uses_native_centralized_xyz_and_pair_requires_terminal_result(tmp_path):
    after=snapshot(2,True);header={'episode_id':'episode','tick':2,'actor_generations':{'a':1,'b':1},
        'collision':False,'training_only':{'state':list(after['positions']),'physical_diagnostics':after}}
    captured=capture_physical_snapshot(header)
    assert captured==after and captured is not after
    header['training_only']['state'][1]=-.1
    with pytest.raises(ValueError):capture_physical_snapshot(header)
    row,meta=record(tmp_path)
    row['physical_diagnostics']={'before':snapshot(),'after':after}
    validate_record(row,meta)
    row['physical_diagnostics']['after']['terminal']=False
    with pytest.raises(ValueError):validate_record(row,meta)


def test_optin_is_required_every_row_and_legacy_omission_stays_valid(tmp_path):
    row,meta=record(tmp_path)
    with pytest.raises(ValueError):validate_record(row,meta)
    del meta['recording_settings']['physical_diagnostics'];validate_record(row,meta)
    row['physical_diagnostics']={'before':snapshot(),'after':snapshot(2,True)}
    with pytest.raises(ValueError):validate_record(row,meta)


def test_physical_pair_rejects_pose_floor_identity_tick_and_unsafe_outcomes(tmp_path):
    row,meta=record(tmp_path);healthy={'before':snapshot(),'after':snapshot(2,True)}
    validate_physical_pair(healthy,row)
    for mutate in (
        lambda x:x['after']['positions'].__setitem__(1,float('nan')),
        lambda x:x['after']['floor_clearance'].__setitem__('a',.02),
        lambda x:x['after']['actor_generations'].__setitem__('a',2),
        lambda x:x['after'].__setitem__('tick',4),
        lambda x:x['after'].__setitem__('collision',True),
        lambda x:x['after']['positions'].__setitem__(1,.79),
        lambda x:x['after'].__setitem__('contact_depths',[]),
        lambda x:x['after'].__setitem__('actor_ids',['a']*65),
    ):
        broken=copy.deepcopy(healthy);mutate(broken)
        with pytest.raises(ValueError):validate_physical_pair(broken,row)


def test_centralized_physics_cannot_enter_actor_schema_or_infos():
    import numpy as np
    from zyren_train.pettingzoo_env import ZyrenParallelEnv
    from zyren_train.protocol import Frame,ProtocolError
    env=ZyrenParallelEnv(None,scenario='pure',possible_agents=['a'],observation_width=4,
        action_space={'kind':'multi_discrete','nvec':[2]})
    h={'version':1,'operation':'reset','sequence':1,'run_id':'fixture','actor_ids':['a'],'actor_generations':{'a':1},'environment_id':'parallel','episode_id':'one','tick':1,
       'observation_schema_hash':'a'*64,'action_schema_hash':'b'*64,'build_id':'c'*64,'split':'training',
       'action_space':{'kind':'multi_discrete','nvec':[2]},'observation_schema':{'fields':[{'id':'body','width':4}]},
       'training_only':{'state':[0,.81,0],'physical_diagnostics':snapshot()}}
    arrays={'observation.a':np.array([.1,.2,.3,.4],dtype='<f4')}
    observations,infos=env._read(Frame.from_arrays(h,arrays))
    assert 'physical_diagnostics' not in infos['a']
    changed=copy.deepcopy(h);changed['training_only']['physical_diagnostics']['positions'][1]=-1
    next_observations,next_infos=env._read(Frame.from_arrays(changed,arrays))
    assert np.array_equal(observations['a'],next_observations['a']) and infos==next_infos
    for field in ('physical_diagnostics','actor_poses','floor_clearance'):
        leaked=copy.deepcopy(h);leaked['observation_schema']['fields'][0]['id']=field
        with pytest.raises(ProtocolError):env._read(Frame.from_arrays(leaked,arrays))


def physical_rows():
    result=[]
    for tick in (2,3):
        result.append({'episode_id':'episode','tick':tick,'actor_generations':{'a':1,'b':1},
            'observations':{'a':[1.]*36,'b':[-1.]*36},'proposed_actions':{'a':[2,2,2,1,0,0],'b':[2,2,2,1,0,0]},
            'applied_actions':{'a':[2,2,2,1,0,0],'b':[2,2,2,1,0,0]},'fallback':{'a':False,'b':False},
            'delay_ticks':{'a':0,'b':0},'reward_terms':{'progress':0.},'terminated':tick==3,'truncated':False,
            'physical_diagnostics':{'before':snapshot(tick-1),'after':snapshot(tick,tick==3)}})
    return result


def physical_recorder(path):
    from zyren_train.demonstration import DemonstrationRecorder
    from zyren_train.scenario import ScenarioSpec
    from test_multi_evaluation import plan_value
    value=plan_value()['cases'][0]['scenario'];value['partition']='train'
    return DemonstrationRecorder(path,scenario=ScenarioSpec.from_dict(value),session_id='session',run_id='run',
        environment_id='env',source='scripted',model_hash='teacher',chunk_records=1,
        recording_settings={'physical_diagnostics':PHYSICAL_CONTRACT})


def test_recording_rejects_discontinuous_physical_before_before_writing(tmp_path):
    recorder=physical_recorder(tmp_path/'physical');first,second=physical_rows()
    recorder.append(first)
    second['physical_diagnostics']['before']['positions'][0]=.5
    with pytest.raises(ValueError,match='continuity'):recorder.append(second)
    assert recorder._steps==1
    recorder.abort()


def test_verified_loader_rejects_rehashed_discontinuous_pair_across_chunks(tmp_path):
    import hashlib
    from dataclasses import replace
    from zyren_train.dataset import DatasetManifest
    from zyren_train.scenario import canonical_bytes
    path=tmp_path/'physical';recorder=physical_recorder(path)
    for row in physical_rows():recorder.append(row)
    manifest=recorder.finalize();assert len(list(manifest.records(path)))==2
    chunk=manifest.chunks[1];row=json.loads((path/chunk.file).read_bytes())
    row['physical_diagnostics']['before']['positions'][0]=.5
    data=canonical_bytes(row)+b'\n';(path/chunk.file).write_bytes(data)
    changed=replace(manifest,chunks=(manifest.chunks[0],replace(chunk,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data))))
    with pytest.raises(ValueError,match='continuity'):list(changed.records(path))


class FramedPhysicalWorker:
    run_id='physical-fixture'
    def __init__(self,*,unsafe=False):self.unsafe=unsafe;self.closed=0
    def call(self,operation,**request):
        import numpy as np
        from zyren_train.protocol import Frame
        from test_multi_evaluation import plan_value
        if operation=='close':self.closed+=1;return None
        if operation=='reset':self.tick=1;self.episode=request['environment_id']+'-1'
        else:self.tick+=1
        physical=snapshot(self.tick,self.tick==3);physical['episode_id']=self.episode
        if self.unsafe and self.tick==2:
            physical['positions'][1]=.79;physical['floor_clearance']['a']=-.01;physical['collision']=True
        spec=plan_value()['cases'][0]['scenario'];spec.update(partition='train',max_steps=2,seed=7)
        spec['settings']['dynamic']=False;spec['reward_terms']=[{'id':'task.progress','cap':1.}]
        action={a:[2,2,2,1,0,0] for a in ('a','b')}
        h={'version':1,'operation':operation,'sequence':self.tick,'run_id':self.run_id,
            'environment_id':request['environment_id'],'episode_id':self.episode,'tick':self.tick,
            'actor_ids':['a','b'],'actor_generations':{'a':1,'b':1},'split':'training',
            'observation_schema_hash':spec['observation_schema_hash'],'action_schema_hash':spec['action_schema_hash'],
            'build_id':spec['game_build_hash'],'physics_backend':'rapier','scenario_spec':spec,
            'action_space':{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},
            'observation_schema':{'fields':[{'id':'actor','width':36}]},
            'per_agent_legality':{a:[[True]*n for n in [5,5,5,3,2,2]] for a in ('a','b')},
            'per_agent_rewards':{'a':0.,'b':0.},'per_agent_terminated':{a:self.tick==3 for a in ('a','b')},
            'per_agent_truncated':{'a':False,'b':False},'terminal_observations':{},
            'applied_actions':action,'per_agent_results':{'a':'win','b':'win'},'collision':physical['collision'],
            'training_only':{'teacher_actions':action,'state':physical['positions'],'physical_diagnostics':physical}}
        return Frame.from_arrays(h,{a:np.ones(36,dtype='<f4') for a in ('observation.a','observation.b')})


def fixture_pins(monkeypatch):
    import zyren_train.multi_recording as module
    monkeypatch.setattr(module,'_worker_pins',lambda _: {'worker_sha256':'a'*64,'worker_native_sha256':{'lib/physics.dylib':'b'*64}})
    return module


def test_capture_and_replay_bind_full_terminal_physics_and_remap_episode_identity(tmp_path,monkeypatch):
    from zyren_train.dataset import DatasetManifest
    module=fixture_pins(monkeypatch);worker=FramedPhysicalWorker();path=tmp_path/'framed'
    receipt=module.record_multi_teacher(worker,'scenario',path,seed=7,capture_physics=True)
    manifest=DatasetManifest.load(path);rows=list(manifest.records(path))
    assert len(rows)==2 and manifest.hash==receipt['manifest_hash']
    assert rows[-1]['physical_diagnostics']['after']['terminal']
    assert manifest.recording['recording_settings']['physical_diagnostics']==PHYSICAL_CONTRACT
    assert module.replay_multi_recording(worker,path)['steps']==2
    assert worker.closed==2
    physical=rows[0]['physical_diagnostics'];physical['before']['positions'][0]=99
    assert next(manifest.records(path))['physical_diagnostics']['before']['positions'][0]==0


def test_failed_floor_admission_aborts_dataset_and_retains_bounded_native_snapshot(tmp_path,monkeypatch):
    module=fixture_pins(monkeypatch);worker=FramedPhysicalWorker(unsafe=True);path=tmp_path/'failed'
    with pytest.raises(ValueError,match='floor'):module.record_multi_teacher(worker,'scenario',path,seed=7,capture_physics=True)
    assert worker.closed==1 and not (path/'manifest.json').exists()
    failure=json.loads((path/'physical-diagnostics-failure.json').read_bytes())
    assert failure['physical_snapshot']['floor_clearance']['a']==-.01
    assert failure['physical_snapshot']['tick']==2 and failure['physical_snapshot']['collision']
    assert failure['native_worker_pins']['worker_sha256']=='a'*64
    assert (path/'physical-diagnostics-failure.json').stat().st_size<65536
