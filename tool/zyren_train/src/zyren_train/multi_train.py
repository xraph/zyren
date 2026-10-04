"""Bounded joint PPO and frozen history over the existing native task transport."""
from dataclasses import dataclass
import copy
import hashlib
import json
from pathlib import Path
import random
import numpy as np
import torch
from .train import TrainingConfig, _pins, _ppo_update, worker_native_hashes
from .checkpoint import TrainingCheckpoint
from .run_manifest import RunDirectory
from .scenario import ScenarioSpec, canonical_bytes
from .normalize import ObservationNormalizer
from .policies.structured import StructuredPolicy
from .policies.cloning import cloning_loss
from .multi_recording import multi_training_sequences, SPACE
from .pettingzoo_env import ZyrenParallelEnv
from .self_play import SelfPlayActors, collect_parallel_rollout
from .opponents import OpponentPool
from .worker import Worker


MAX_MULTI_UPDATES=4096


@dataclass(frozen=True)
class MultiTrainingConfig:
    encoded:bytes
    @classmethod
    def from_dict(cls,value):
        if not isinstance(value,dict) or not {'schema_version','task','training','history_every_updates','history_versions'}<=set(value) or set(value)-{'schema_version','task','training','history_every_updates','history_versions','cloning_order'} or value['schema_version']!=2 or value['task'] not in ('cooperative-search','competitive-pursuit'):
            raise ValueError('Multi training schema differs')
        if 'cloning_order' in value and value['cloning_order']!='seeded-per-epoch-v1':raise ValueError('Multi cloning order differs')
        if type(value['history_every_updates']) is not int or not 1<=value['history_every_updates']<=128 or type(value['history_versions']) is not int or not 4<=value['history_versions']<=8:
            raise ValueError('Multi history budget differs')
        config=TrainingConfig.from_dict(value['training']);data=config.data
        if data['rollout']['environments']!=1 or data['network']!={'hidden_sizes':[128,128],'lstm_hidden_size':128} or data['policy_distribution']!='masked-categorical-v1' or any(key in data for key in ('initial_actor','derived_rewards','demonstration_regularization')):
            raise ValueError('Bounded structured multi training profile required')
        if len(data['curriculum'])!=1:raise ValueError('Multi training requires one explicit TRAIN stage')
        if data['total_steps']//data['rollout']['steps']>MAX_MULTI_UPDATES:raise ValueError('Multi update budget exceeded')
        if data['total_steps']%data['rollout']['steps']:raise ValueError('Multi budget requires whole native rollouts')
        callback='cooperative.search' if value['task']=='cooperative-search' else 'competitive.pursuit'
        if any(s['callback_id']!=callback or s['settings'].get('fixed_hz')!=50 or s['control_cadence']!=1 or s['latency_ticks']!=1 for s in data['scenarios']):
            raise ValueError('Shared multi clock/task ABI differs')
        return cls(canonical_bytes(value))
    @property
    def data(self):return json.loads(self.encoded)
    @property
    def hash(self):return hashlib.sha256(self.encoded).hexdigest()
    @classmethod
    def load(cls,path):return cls.from_dict(json.loads(Path(path).read_bytes()))


def cloning_sequence_order(count,seed,epoch,*,enabled):
    if type(count) is not int or not 1<=count<=(4096 if enabled else 1_000_000) or type(seed) is not int or not 0<=seed<2**53 or type(epoch) is not int or not 0<=epoch<=100000 or type(enabled) is not bool:
        raise ValueError('Cloning sequence order budget differs')
    order=list(range(count))
    if enabled:random.Random(f'multi-bc:{seed}:{epoch}').shuffle(order)
    return order


def train_multi(config,path,command,*,cwd,resume=False,cancelled=lambda:False,stop_after_updates=None):
    value=config.data;data=value['training'];base=TrainingConfig.from_dict(data)
    if stop_after_updates is not None and (type(stop_after_updates) is not int or not 1<=stop_after_updates<=10000):raise ValueError('Invocation update limit differs')
    if len(command)!=1 or hashlib.sha256(Path(command[0]).read_bytes()).hexdigest()!=data['worker_sha256'] or worker_native_hashes(command[0])!=data['worker_native_sha256']:
        raise ValueError('Frozen training worker bytes differ')
    parts=_pins(base);source_pins={name:[m.hash for _,m in part.recordings] for name,part in parts.items()}
    normalizer=ObservationNormalizer.fit(parts['train']) if 'train' in parts else None
    norm=None if normalizer is None else dict(normalizer.__dict__)
    run=RunDirectory(path,config.hash,resume=resume);run.acquire()
    worker=env=None;steps=updates=transitions=episode_serial=0;cloning={'epoch':0,'sequence':0,'complete':data['bc_epochs']==0}
    history=OpponentPool(value['history_versions'],seed=data['seed'])
    try:
        torch.set_num_threads(1);torch.manual_seed(data['seed']);random.seed(data['seed']);np.random.seed(data['seed'])
        policy=StructuredPolicy(36,SPACE,fallback=[2,2,2,1,0,0],**({} if normalizer is None else {'mean':normalizer.mean,'scale':normalizer.scale}))
        optimizer=torch.optim.Adam(policy.parameters(),lr=data['optimizer']['learning_rate'])
        if resume:
            state=TrainingCheckpoint.load(run,config.hash)
            if state['normalization']!=norm or state['source_pins']!=source_pins:raise ValueError('Resume source data/normalization differs')
            saved=state['curriculum'];history=OpponentPool.from_dict(saved['history'])
            if history.purpose!='training' or any(e['partition']!='train' for e in history.to_dict()['entries']):raise ValueError('Withheld opponents cannot enter training')
            policy.load_state_dict(state['model']);optimizer.load_state_dict(state['optimizer']);TrainingCheckpoint.restore_rng(state)
            steps=state['steps'];updates=state['updates'];transitions=saved['actor_transitions'];episode_serial=saved['episode_serial'];cloning=state['cloning_progress']
            if type(transitions) is not int or transitions<steps or set(cloning)!={'epoch','sequence','complete'} or not 0<=cloning['epoch']<=data['bc_epochs'] or cloning['complete']!=(cloning['epoch']==data['bc_epochs']):raise ValueError('Multi resume progress differs')
        else:(run.path/'config.json').write_bytes(config.encoded+b'\n')
        last_checkpoint_steps=steps
        def actor_digest(weights):
            digest=hashlib.sha256()
            for key,tensor in sorted(weights.items()):
                if key.startswith('value_head.'):continue
                digest.update(key.encode());digest.update(tensor.detach().cpu().contiguous().numpy().tobytes())
            return digest.hexdigest()
        def snapshot(label):
            nonlocal history
            actor_sha=actor_digest(policy.state_dict())
            for previous in history.to_dict()['entries']:
                old=torch.load(previous['path'],map_location='cpu',weights_only=True)
                if old['actor_weights_sha256']==actor_sha:raise ValueError('Historical actor weights did not change')
            version=f'{label}-{actor_sha[:16]}-{run.sequence:06d}'
            file=run.path/f'history-{version}.pt'
            with file.open('xb') as stream:torch.save({'model':policy.state_dict(),'config_hash':config.hash,'actor_weights_sha256':actor_sha},stream)
            spec=ScenarioSpec.from_dict(data['scenarios'][0])
            entry={'version':version,'path':str(file.resolve()),'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),
                'observation_schema_hash':spec.observation_schema_hash,'action_schema_hash':spec.action_schema_hash,'partition':'train','weight':1.}
            if len(history.to_dict()['entries'])==history.max_versions:
                old=history.to_dict();old['entries']=old['entries'][1:];history=OpponentPool.from_dict(old)
            history.add(entry);run.append('running',phase='historical-policy',version=version,policy_sha256=entry['sha256'],actor_weights_sha256=actor_sha)
        def save():
            nonlocal last_checkpoint_steps
            checkpoint=TrainingCheckpoint.save(run,policy=policy,optimizer=optimizer,steps=steps,updates=updates,
                curriculum={'history':history.to_dict(),'actor_transitions':transitions,'episode_serial':episode_serial},normalization=norm,
                config_hash=config.hash,source_pins=source_pins,cloning_progress=cloning)
            run.append('running',phase='checkpoint',checkpoint=checkpoint.path.name,checkpoint_sha256=checkpoint.sha256,
                steps=steps,updates=updates,environment_restore='reset-boundary')
            last_checkpoint_steps=steps
            return checkpoint
        if not resume:save()
        while not cloning['complete'] and not cancelled():
            sequences=list(multi_training_sequences(parts['train'],policy))
            order=cloning_sequence_order(len(sequences),data['seed'],cloning['epoch'],enabled=value.get('cloning_order')=='seeded-per-epoch-v1')
            for position in range(cloning['sequence'],len(sequences)):
                if cancelled():break
                loss=cloning_loss(policy,*sequences[order[position]]);optimizer.zero_grad();loss.backward()
                torch.nn.utils.clip_grad_norm_(policy.parameters(),data['optimizer']['max_grad_norm'],error_if_nonfinite=True);optimizer.step()
                if any(not torch.isfinite(t).all() for t in policy.state_dict().values()):raise ValueError('Nonfinite multi actor weights')
                cloning['sequence']=position+1
            if cloning['sequence']==len(sequences):
                cloning.update(epoch=cloning['epoch']+1,sequence=0)
                cloning['complete']=cloning['epoch']==data['bc_epochs']
                snapshot(f'bc-{cloning["epoch"]:04d}')
                run.append('running',phase='cloning',epoch=cloning['epoch'],actor_sequences=len(sequences),loss=float(loss.detach()),
                    **({'sequence_order':order} if value.get('cloning_order')=='seeded-per-epoch-v1' else {}))
            save()
        if not cancelled():
            worker=Worker(command,cwd=cwd,run_id=config.hash[:24],timeout=60)
            scenario=data['curriculum'][0]['scenario'];spec=next(ScenarioSpec.from_dict(s) for s in data['scenarios'] if s['id']==scenario)
            env=ZyrenParallelEnv(worker,scenario=scenario,possible_agents=['a','b'],observation_width=36,action_space=SPACE,environment_id='multi-train',purpose='training')
            observations,infos=env.reset(seed=data['seed']+steps)
            if ScenarioSpec.from_dict(env._header['scenario_spec']).hash!=spec.hash:raise ValueError('Pinned native TRAIN scenario differs')
            invocation=0;actors=None;new_episode=True
            while steps<data['total_steps'] and not cancelled():
                if updates>=MAX_MULTI_UPDATES:raise ValueError('Multi actual update budget exceeded')
                if new_episode:
                    frozen={};learners=['a','b'];entry=None
                    if value['task']=='competitive-pursuit' and history.to_dict()['entries']:
                        actor='b' if episode_serial%2==0 else 'a';entry=history.sample();frozen_policy=copy.deepcopy(policy)
                        saved=torch.load(entry['path'],map_location='cpu',weights_only=True)
                        if saved['config_hash']!=config.hash or saved['actor_weights_sha256']!=actor_digest(saved['model']):raise ValueError('Historical config/actor bytes differ')
                        frozen_policy.load_state_dict(saved['model']);frozen_policy.requires_grad_(False);frozen[actor]=frozen_policy
                        learners=['a' if actor=='b' else 'b']
                    if episode_serial or resume:observations,infos=env.reset(seed=data['seed']+steps)
                    actors=SelfPlayActors(policy,frozen=frozen);episode_serial+=1;new_episode=False
                batch,observations,infos,receipt=collect_parallel_rollout(env,actors,observations,infos,
                    steps=min(data['rollout']['steps'],data['total_steps']-steps),learners=learners,reset_seed=data['seed']+steps+1,
                    stop_at_episode_boundary=True)
                new_episode=receipt['episodes']>0
                metrics=_ppo_update(policy,optimizer,batch,data['optimizer'])
                if any(not torch.isfinite(t).all() for t in policy.state_dict().values()):raise ValueError('Nonfinite multi actor weights')
                steps+=receipt['native_steps'];transitions+=receipt['actor_transitions'];updates+=1;invocation+=1
                run.append('running',phase='joint-ppo',steps=steps,updates=updates,actor_transitions=transitions,learners=learners,metrics=metrics,
                    sampled_history=None if not frozen else entry['version'],native_completed_tick=receipt['completed_tick'],training_only_actor_inputs=receipt['training_only_actor_inputs'])
                if updates%value['history_every_updates']==0:snapshot(f'ppo-{updates:06d}')
                if steps-last_checkpoint_steps>=data['checkpoint_every_steps'] or steps==data['total_steps'] or stop_after_updates is not None and invocation>=stop_after_updates:save()
                if stop_after_updates is not None and invocation>=stop_after_updates:break
        checkpoint=save();status='completed' if steps==data['total_steps'] and cloning['complete'] else 'cancelled'
        if env is not None:env.close();env=None
        exits=[]
        if worker is not None:worker.close();exits=[worker.process.returncode];worker=None
        if exits and any(code!=0 for code in exits):raise RuntimeError('Native training worker cleanup failed')
        if hashlib.sha256(Path(command[0]).read_bytes()).hexdigest()!=data['worker_sha256'] or worker_native_hashes(command[0])!=data['worker_native_sha256']:raise ValueError('Native training worker changed')
        current_parts=_pins(base)
        if {name:[m.hash for _,m in part.recordings] for name,part in current_parts.items()}!=source_pins:raise ValueError('TRAIN datasets changed during training')
        return run.append(status,steps=steps,updates=updates,actor_transitions=transitions,
            checkpoint=checkpoint.path.name,checkpoint_sha256=checkpoint.sha256,history=history.to_dict(),
            workers_closed=True,worker_exit_codes=exits,quality=None,numerical_reproducibility=False,environment_restore='reset-boundary')
    except BaseException as error:
        run.append('cancelled' if isinstance(error,KeyboardInterrupt) else 'failed',steps=steps,updates=updates,error=str(error)[:4096])
        raise
    finally:
        try:
            if env is not None:env.close()
        finally:
            if worker is not None:worker.close()
            run.release()
