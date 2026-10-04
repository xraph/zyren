"""Record joint TRAIN controllers through the existing bounded dataset contract."""
import hashlib
import json
from pathlib import Path
import numpy as np
import torch
from .dataset import DatasetPartition, DatasetManifest
from .demonstration import DemonstrationRecorder
from .pettingzoo_env import ZyrenParallelEnv
from .scenario import ScenarioSpec, canonical_bytes
from .train import worker_native_hashes
from .multi_physical_diagnostics import PHYSICAL_CONTRACT,capture_physical_snapshot,compare_physical_snapshot

SPACE={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]}
MODES={'joint-teacher':('a','b'),'stationary-pursuer':('b',),'stationary-evader':('a',)}


def _worker_pins(worker):
    command=worker.process.args
    if not isinstance(command,list) or len(command)!=1:raise ValueError('Frozen native worker command required')
    executable=Path(command[0])
    return {'worker_sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),
            'worker_native_sha256':worker_native_hashes(executable)}


def record_multi_teacher(worker,scenario,path,*,seed,mode='joint-teacher',capture_physics=False):
    if type(capture_physics) is not bool:raise ValueError('Physical capture must be explicit boolean')
    if mode not in MODES or type(seed) is not int or not 0<=seed<2**31:raise ValueError('Bounded multi TRAIN recording request required')
    pins=_worker_pins(worker);name='multi-record-'+hashlib.sha256(str(path).encode()).hexdigest()[:16]
    env=ZyrenParallelEnv(worker,scenario=scenario,possible_agents=['a','b'],observation_width=36,
        action_space=SPACE,environment_id=name,purpose='training')
    recorder=None;steps=0
    try:
        observations,infos=env.reset(seed=seed);h=env._header
        spec=ScenarioSpec.from_dict(h['scenario_spec'])
        if spec.partition!='train' or spec.max_steps>400 or h.get('physics_backend')!='rapier':raise ValueError('Only bounded native TRAIN worlds can supply teachers')
        if capture_physics and (spec.settings.get('dynamic') is not False or set(h['actor_generations'])!={'a','b'}):raise ValueError('Physical recording needs the static controlled actor pair')
        if mode!='joint-teacher' and spec.callback_id!='competitive.pursuit':raise ValueError('Stationary role opponents are competitive only')
        recorder=DemonstrationRecorder(path,scenario=spec,session_id=name,run_id=worker.run_id,environment_id=name,
            source='scripted',model_hash='permitted-multi-teacher-v2',compression='gzip',
            recording_settings={**pins,'learner_actors':list(MODES[mode]),'teacher_contract':'permitted-sensor-route-memory-v2','mode':mode,
                **({'physical_diagnostics':PHYSICAL_CONTRACT} if capture_physics else {})})
        while env.agents and steps<spec.max_steps:
            before=env._header
            before_physics=capture_physical_snapshot(before) if capture_physics else None
            teacher=env.training_only['teacher_actions']
            proposed={a:np.asarray(teacher[a] if a in MODES[mode] else [2,2,2,1,0,0],dtype=np.int64) for a in env.agents}
            captured={a:value.tolist() for a,value in observations.items()}
            legality={a:infos[a]['legality'] for a in env.agents}
            observations,rewards,terminated,truncated,infos=env.step(proposed);steps+=1;h=env._header
            applied={a:h['applied_actions'][a] for a in proposed}
            if any(not np.array_equal(v,applied[a]) for a,v in proposed.items()):raise ValueError('Native teacher action was rejected')
            recorder.append({'episode_id':before['episode_id'],'tick':h['tick'],
                'actor_generations':before['actor_generations'],'observations':captured,
                'proposed_actions':{a:v.tolist() for a,v in proposed.items()},'applied_actions':applied,
                'fallback':{a:False for a in proposed},'delay_ticks':{a:0 for a in proposed},
                'reward_terms':{'task.progress':sum(rewards.values())},'terminated':not env.agents,
                'truncated':False,'legality':legality,
                **({'physical_diagnostics':{'before':before_physics,'after':capture_physical_snapshot(h)}} if capture_physics else {})})
        if env.agents:raise ValueError('Native recording failed to finish within its pinned horizon')
        if _worker_pins(worker)!=pins:raise ValueError('Native worker changed during TRAIN recording')
        manifest=recorder.finalize()
        return {'manifest_hash':manifest.hash,'steps':steps,'learner_actors':list(MODES[mode]),
                'results':h['per_agent_results'],'collision':h['collision'],'scenario_hash':spec.hash,**pins}
    except Exception as error:
        try:
            if capture_physics and recorder is not None:
                failure={'schema_version':1,'error':str(error)[:1024],'native_worker_pins':pins}
                try:failure['physical_snapshot']=capture_physical_snapshot(env._header,require_admission=False)
                except ValueError:failure['physical_snapshot']=None
                with (Path(path)/'physical-diagnostics-failure.json').open('xb') as stream:stream.write(canonical_bytes(failure,max_bytes=65536)+b'\n')
        except (OSError,ValueError):pass
        finally:
            if recorder is not None:recorder.abort()
        raise
    finally:env.close()


def multi_training_sequences(partition,policy,*,max_rows=1_000_000):
    if not isinstance(partition,DatasetPartition) or partition.name!='train' or not partition.recordings:
        raise ValueError('Verified multi TRAIN recordings required')
    for _ in partition.observation_samples():pass
    total=0
    for path,manifest in partition.recordings:
        if DatasetManifest.load(path).hash!=manifest.hash:raise ValueError('Multi TRAIN manifest changed')
        learners=manifest.recording.get('recording_settings',{}).get('learner_actors')
        if learners not in (('a',),('b',),('a','b')):raise ValueError('Registered learner identities required')
        entries={a:[] for a in learners};episode=None;generations=None
        for row in manifest.records(path):
            if episode is not None and row['episode_id']!=episode:raise ValueError('Missing joint episode boundary')
            episode=row['episode_id']
            if generations is not None and row['actor_generations']!=generations:raise ValueError('Actor generation changed inside a cloning graph')
            generations=row['actor_generations']
            if not set(learners)<=set(row['observations']):raise ValueError('A pinned learner departed its cloning graph')
            for a in learners:
                values=row['observations'][a];action=row['applied_actions'][a];masks=row['legality'][a]
                if len(values)!=policy.width or len(action)!=len(policy.nvec) or len(masks)!=len(policy.nvec) or any(v!=int(v) or not 0<=v<n or not masks[b][int(v)] for b,(v,n) in enumerate(zip(action,policy.nvec))):
                    raise ValueError('Multi cloning tensor/action/mask differs')
                entries[a].append((values,action,masks));total+=1
                if len(entries[a])>1024 or total>max_rows:raise ValueError('Multi cloning memory budget exceeded')
            if row['terminated'] or row['truncated']:
                for a in learners:
                    values,actions,masks=zip(*entries[a])
                    obs=torch.tensor(values,dtype=torch.float32).unsqueeze(1)
                    act=torch.tensor(actions,dtype=torch.long).unsqueeze(1)
                    starts=torch.zeros(obs.shape[:2],dtype=torch.bool);starts[0]=True
                    legal=[torch.tensor([m[b] for m in masks],dtype=torch.bool).unsqueeze(1) for b in range(len(policy.nvec))]
                    yield obs,act,starts,legal,torch.ones_like(starts)
                entries={a:[] for a in learners};episode=None;generations=None
        if episode is not None:raise ValueError('Multi cloning source has an unfinished episode')


def replay_multi_recording(worker,path,*,atol=1e-6):
    manifest=DatasetManifest.load(path);spec=ScenarioSpec.from_dict(json.loads(canonical_bytes(manifest.recording['scenario'])))
    if spec.partition!='train':raise ValueError('Multi demonstration replay requires TRAIN data')
    before=_worker_pins(worker)
    if any(before[k]!=manifest.recording['recording_settings'][k] for k in before):raise ValueError('Multi replay worker pins differ')
    env=ZyrenParallelEnv(worker,scenario=spec.id,possible_agents=['a','b'],observation_width=36,
        action_space=SPACE,environment_id='multi-replay',purpose='training')
    steps=0
    try:
        observations,infos=env.reset(seed=spec.seed)
        replay_episode_id=env._header['episode_id']
        capture_physics=manifest.recording['recording_settings'].get('physical_diagnostics')==PHYSICAL_CONTRACT
        if ScenarioSpec.from_dict(env._header['scenario_spec']).hash!=spec.hash:raise ValueError('Multi replay scenario differs')
        for row in manifest.records(path):
            if capture_physics:compare_physical_snapshot(capture_physical_snapshot(env._header),row['physical_diagnostics']['before'],atol=atol,replay_episode_id=replay_episode_id)
            if env._header['actor_generations']!=row['actor_generations'] or any(not np.allclose(observations[a],v,atol=atol,rtol=0) for a,v in row['observations'].items()):raise ValueError('Multi replay actor inputs differ')
            actions={a:np.asarray(v,dtype=np.int64) for a,v in row['applied_actions'].items()}
            observations,rewards,_,_,infos=env.step(actions);steps+=1;h=env._header
            if capture_physics:compare_physical_snapshot(capture_physical_snapshot(h),row['physical_diagnostics']['after'],atol=atol,replay_episode_id=replay_episode_id)
            if h['tick']!=row['tick'] or h['applied_actions']!=row['applied_actions'] or (not env.agents)!=row['terminated'] or abs(sum(rewards.values())-row['reward_terms']['task.progress'])>atol:raise ValueError('Multi replay native controller outcomes differ')
        if _worker_pins(worker)!=before:raise ValueError('Multi replay worker changed')
        return {'steps':steps,'manifest_hash':manifest.hash,'native_backend':'rapier'}
    finally:env.close()
