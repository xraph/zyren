"""Local behavior cloning and recurrent PPO through the native step protocol."""
from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import math
import random
import numpy as np
import torch
from .scenario import ScenarioSpec, canonical_bytes, decode_json_bytes
from .dataset import DatasetPartition
from .normalize import ObservationNormalizer
from .split import validate_partitions
from .worker import Worker
from .gym_env import ZyrenEnv
from .run_manifest import RunDirectory
from .checkpoint import TrainingCheckpoint
from .curriculum import Curriculum
from .rewards import RewardLedger
from .policies.structured import StructuredPolicy
from .policies.cloning import training_sequences, cloning_loss


def worker_native_hashes(executable):
    root=Path(executable).resolve().parent.parent; directory=root/'lib'
    files=sorted(p for p in directory.rglob('*') if p.is_file()) if directory.is_dir() else []
    if not files or len(files)>16: raise ValueError('Prepared worker copied native assets are required')
    result={}
    for path in files:
        if path.is_symlink() or not path.resolve().is_relative_to(root) or path.stat().st_size>268_435_456: raise ValueError('Invalid native artifact boundary')
        digest=hashlib.sha256()
        with path.open('rb') as stream:
            while value:=stream.read(1_048_576): digest.update(value)
        result[str(path.relative_to(root))]=digest.hexdigest()
    return result


@dataclass(frozen=True)
class TrainingConfig:
    encoded: bytes
    @classmethod
    def from_dict(cls,data):
        required={'schema_version','seed','device','algorithm','network','optimizer','rollout','total_steps','checkpoint_every_steps','evaluation_every_steps','scenarios','curriculum','rewards','datasets','bc_epochs','worker_sha256','worker_native_sha256','policy_distribution'}
        if set(data)!=required or type(data['schema_version']) is not int or data['schema_version']!=1 or data['device']!='cpu' or data['algorithm']!='recurrent_ppo': raise ValueError('Unsupported training configuration')
        def bounded(value,low,high):
            if type(value) is not int or not low<=value<=high: raise ValueError('Training budget is invalid')
        bounded(data['seed'],0,2**31-1); bounded(data['total_steps'],1,10_000_000)
        bounded(data['checkpoint_every_steps'],1,10_000_000); bounded(data['evaluation_every_steps'],1,10_000_000); bounded(data['bc_epochs'],0,100)
        if data['network']!={'hidden_sizes':[128,128],'lstm_hidden_size':128}: raise ValueError('Unsupported structured architecture')
        rollout=data['rollout']
        if set(rollout)!={'environments','steps'}: raise ValueError('Unknown rollout field')
        bounded(rollout['environments'],1,8); bounded(rollout['steps'],2,256)
        if data['total_steps']%rollout['environments']: raise ValueError('Budget must cover whole vector transitions')
        optimizer=data['optimizer']
        if set(optimizer)!={'learning_rate','epochs','gamma','gae_lambda','clip','entropy','value','max_grad_norm'}: raise ValueError('Optimizer pins are incomplete')
        bounded(optimizer['epochs'],1,10)
        for key in ('learning_rate','gamma','gae_lambda','clip','entropy','value','max_grad_norm'):
            value=optimizer[key]
            if type(value) not in (int,float) or not math.isfinite(value) or not 0<=value<=10: raise ValueError('Optimizer pin is invalid')
        if not 0<optimizer['learning_rate']<=.1 or not 0<optimizer['gamma']<=1 or not 0<optimizer['gae_lambda']<=1 or not 0<optimizer['clip']<1 or optimizer['max_grad_norm']<=0: raise ValueError('Optimizer bounds differ')
        import re
        if not re.fullmatch('[0-9a-f]{64}',data['worker_sha256']): raise ValueError('Prepared worker SHA256 is required')
        assets=data['worker_native_sha256']
        if not isinstance(assets,dict) or not assets or len(assets)>16 or any(not re.fullmatch(r'lib/[A-Za-z0-9_.-]+',name) or not re.fullmatch('[0-9a-f]{64}',digest) for name,digest in assets.items()): raise ValueError('Copied native asset pins are required')
        if not data['scenarios'] or len(data['scenarios'])>64: raise ValueError('Missing or oversized scenario split')
        specs={item['id']:ScenarioSpec.from_dict(item) for item in data['scenarios']}
        if len(specs)!=len(data['scenarios']) or len({s.hash for s in specs.values()})!=len(specs): raise ValueError('Duplicate scenario content or identity')
        if len({s.observation_schema_hash for s in specs.values()})!=1 or len({s.action_schema_hash for s in specs.values()})!=1: raise ValueError('One policy requires one observation/action profile')
        curriculum=Curriculum(tuple(data['curriculum']))
        if any(stage['scenario'] not in specs or specs[stage['scenario']].partition!='train' for stage in curriculum.stages): raise ValueError('Held-out scenario cannot enter curriculum')
        if data['policy_distribution'] not in ('masked-categorical-v1','censored-normal-v1'): raise ValueError('Unsupported policy distribution')
        RewardLedger(data['rewards'])
        if set(data['datasets'])!={'train','validation','test'} or any(not isinstance(v,list) or len(v)>10000 or any(not isinstance(p,str) or not p for p in v) for v in data['datasets'].values()): raise ValueError('Dataset split pins are incomplete')
        if data['bc_epochs'] and not data['datasets']['train']: raise ValueError('Cloning requires verified training data')
        return cls(canonical_bytes(data))
    @classmethod
    def load(cls,path):
        # JSON is a YAML1.2 subset. Configs remain readable without another parser.
        return cls.from_dict(decode_json_bytes(Path(path).read_bytes()))
    @property
    def data(self): return json.loads(self.encoded)
    @property
    def hash(self): return hashlib.sha256(self.encoded).hexdigest()


class WorkerPool:
    """Own one prepared supervisor and bounded independent environment instances."""
    def __init__(self,command,*,cwd,config):
        self.config=config; data=config.data; self.worker=None; self.envs=[]; self.observations=[]; self.infos=[]; self.closed=False; self.exit_codes=[]; self.serials=[]
        executable=Path(command[0]).resolve()
        if len(command)!=1 or not executable.is_file() or hashlib.sha256(executable.read_bytes()).hexdigest()!=data['worker_sha256']: raise ValueError('Worker artifact differs from training pin')
        if worker_native_hashes(executable)!=data['worker_native_sha256']: raise ValueError('Native worker asset bytes differ')
        self.worker=Worker([str(executable)],cwd=cwd,run_id=config.hash[:24])
        self.specs={item['id']:ScenarioSpec.from_dict(item) for item in data['scenarios']}
        for i in range(data['rollout']['environments']): self.envs.append(None); self.observations.append(None); self.infos.append(None); self.serials.append(0)
    def reset(self,index,scenario,seed):
        if self.closed or scenario not in self.specs or self.specs[scenario].partition!='train': raise ValueError('Only registered training scenarios can reset this pool')
        previous=self.envs[index]
        if previous is not None: previous.close()
        self.serials[index]+=1
        env=ZyrenEnv(self.worker,environment_id=f'train-{index}-{self.serials[index]}',scenario=scenario,observation_width=None)
        self.envs[index]=env
        observation,info=env.reset(seed=seed)
        spec=self.specs[scenario]
        actual=ScenarioSpec.from_dict(info['scenario_spec'])
        if actual.hash!=spec.hash or info['build_id']!=spec.game_build_hash or info['observation_schema_hash']!=spec.observation_schema_hash or info['action_schema_hash']!=spec.action_schema_hash: raise ValueError('Live scenario/schema/build pins differ')
        self.observations[index],self.infos[index]=observation,info
        return observation,info
    def close(self):
        if self.closed: return
        self.closed=True
        try:
            for env in self.envs:
                if env is not None: env.close()
        finally:
            if self.worker is not None:
                self.worker.close(); self.exit_codes=[self.worker.process.returncode]


def _pins(config):
    result={}
    for name,paths in config.data['datasets'].items():
        if paths: result[name]=DatasetPartition.from_recordings(name,paths)
    if result: validate_partitions(result)
    specs={item['id']:ScenarioSpec.from_dict(item) for item in config.data['scenarios']}
    allowed={name:{s.hash for s in specs.values() if s.partition==name} for name in ('train','validation','test')}
    for name,partition in result.items():
        if not partition.scenario_hashes<=allowed[name]: raise ValueError('Dataset scenario does not belong to pinned split')
    return result


def _masks(infos,nvec):
    if not nvec: return None
    if any('legality' not in info or len(info['legality'])!=len(nvec) for info in infos): raise ValueError('Host legality is required')
    return [torch.tensor([info['legality'][b] for info in infos],dtype=torch.bool) for b in range(len(nvec))]


def _gae(rewards,values,dones,bootstrap,gamma,lam):
    result=torch.zeros_like(rewards); carry=torch.zeros_like(bootstrap)
    next_value=bootstrap
    for tick in reversed(range(len(rewards))):
        active=(~dones[tick]).float(); delta=rewards[tick]+gamma*next_value*active-values[tick]
        carry=delta+gamma*lam*active*carry; result[tick]=carry; next_value=values[tick]
    return result,result+values


def _ppo_update(policy,optimizer,batch,settings):
    observations,actions,starts,masks,old_logprob,old_values,rewards,dones,bootstrap,initial=batch
    advantages,returns=_gae(rewards,old_values,dones,bootstrap,settings['gamma'],settings['gae_lambda'])
    advantages=(advantages-advantages.mean())/(advantages.std(unbiased=False)+1e-8)
    receipt={}
    for _ in range(settings['epochs']):
        outputs,values,_=policy.sequence(observations,starts,state=initial)
        distribution=policy.distribution(outputs,masks)
        logprob=distribution.log_prob(actions); ratio=(logprob-old_logprob).exp()
        if not torch.isfinite(ratio).all(): raise ValueError('Nonfinite PPO ratio')
        actor=-torch.minimum(ratio*advantages,ratio.clamp(1-settings['clip'],1+settings['clip'])*advantages).mean()
        critic=(values-returns).square().mean(); entropy=distribution.entropy().mean()
        loss=actor+settings['value']*critic-settings['entropy']*entropy
        if not torch.isfinite(loss): raise ValueError('Nonfinite training loss')
        optimizer.zero_grad(); loss.backward()
        grad=torch.nn.utils.clip_grad_norm_(policy.parameters(),settings['max_grad_norm'],error_if_nonfinite=True); optimizer.step()
        receipt={'loss':float(loss.detach()),'actor_loss':float(actor.detach()),'value_loss':float(critic.detach()),'entropy':float(entropy.detach()),'gradient_norm':float(grad)}
    return receipt


TRAINERS={}
def train(config,pool,run,*,resume=False,stop_after_updates=None,cancelled=lambda:False):
    return TRAINERS[config.data['algorithm']](config,pool,run,resume=resume,stop_after_updates=stop_after_updates,cancelled=cancelled)


def recurrent_ppo(config,pool,run,*,resume=False,stop_after_updates=None,cancelled=lambda:False):
    if pool.config.hash!=config.hash or run.config_hash!=config.hash: raise ValueError('Training run/pool pins differ')
    data=config.data; steps=updates=0; checkpoint=None; status='failed'; ledger=RewardLedger(data['rewards'])
    try:
        run.acquire()
    except BaseException:
        pool.close(); raise
    try:
        torch.set_num_threads(1); torch.manual_seed(data['seed']); random.seed(data['seed']); np.random.seed(data['seed'])
        curriculum=Curriculum(tuple(data['curriculum'])); parts=_pins(config)
        source_pins={name:[manifest.hash for _,manifest in part.recordings] for name,part in parts.items()}
        normalizer=ObservationNormalizer.fit(parts['train']) if 'train' in parts else None
        norm=None if normalizer is None else dict(normalizer.__dict__)
        state=TrainingCheckpoint.load(run,config.hash) if resume else None
        if state is not None:
            if state['normalization']!=norm or state.get('source_pins')!=source_pins: raise ValueError('Resume source data or normalization changed')
            steps,updates=state['steps'],state['updates']; curriculum.restore(state['curriculum'])
        scenario=curriculum.at_boundary(steps)
        for index in range(len(pool.envs)): pool.reset(index,scenario,data['seed']+steps+index)
        first=pool.infos[0]; width=sum(field['width'] for field in first['observation_schema']['fields'])
        if any(info['action_space']!=first['action_space'] or info['observation_schema_hash']!=first['observation_schema_hash'] for info in pool.infos): raise ValueError('Vector profiles differ')
        fallback=first['action_schema']['fallbackDiscrete'] if first['action_space']['kind']=='multi_discrete' else None
        policy=StructuredPolicy(width,first['action_space'],fallback=fallback,mean=None if norm is None else norm['mean'],scale=None if norm is None else norm['scale'])
        if policy.distribution_id!=data['policy_distribution']: raise ValueError('Policy distribution and host action contract differ')
        optimizer=torch.optim.Adam(policy.parameters(),lr=data['optimizer']['learning_rate'])
        if state is not None:
            if state['policy_distribution']!=policy.distribution_id: raise ValueError('Checkpoint policy distribution differs')
            policy.load_state_dict(state['model']); optimizer.load_state_dict(state['optimizer']); TrainingCheckpoint.restore_rng(state)
        run.append('running',phase='resume' if resume else 'start',steps=steps,updates=updates,
                   environment_restore='reset-boundary',numerical_reproducibility=False,source_pins=source_pins,
                   observation_schema_hash=first['observation_schema_hash'],action_schema_hash=first['action_schema_hash'],
                   generated_observation_width=width,policy_distribution=policy.distribution_id,worker_sha256=data['worker_sha256'],worker_native_sha256=data['worker_native_sha256'])
        if state is None and data['bc_epochs']:
            for epoch in range(data['bc_epochs']):
                losses=[]
                for sequence in training_sequences(parts['train'],policy):
                    optimizer.zero_grad(); loss=cloning_loss(policy,*sequence)
                    if not torch.isfinite(loss): raise ValueError('Cloning action violates captured legality')
                    loss.backward(); torch.nn.utils.clip_grad_norm_(policy.parameters(),data['optimizer']['max_grad_norm'],error_if_nonfinite=True); optimizer.step(); losses.append(float(loss.detach()))
                if not losses: raise ValueError('Cloning partition is empty')
                run.append('running',phase='behavior-cloning',epoch=epoch,loss=sum(losses)/len(losses),steps=steps,updates=updates)
        count=len(pool.envs); hidden=policy.initial_state(count); starts=torch.ones(count,dtype=torch.bool); since_checkpoint=steps; since_evaluation=steps
        invocation_updates=0
        while steps<data['total_steps'] and not cancelled():
            length=min(data['rollout']['steps'],(data['total_steps']-steps)//count)
            initial=tuple(value.detach().clone() for value in hidden)
            rows=[]; legal_rows=[]
            for _ in range(length):
                observation=torch.tensor(np.stack(pool.observations),dtype=torch.float32); masks=_masks(pool.infos,policy.nvec)
                with torch.no_grad():
                    outputs,values,hidden=policy.step(observation,hidden,starts)
                    distribution=policy.distribution(outputs,masks); action=distribution.sample(); logprob=distribution.log_prob(action)
                rewards=[]; done=[]
                captured_starts=starts.clone()
                for index,env in enumerate(pool.envs):
                    observed,_,terminal,truncated,info=env.step(action[index].numpy())
                    rewards.append(ledger.apply(info,environment_id=f'train-{index}')); done.append(terminal or truncated)
                    pool.observations[index],pool.infos[index]=observed,info
                    if done[-1]: pool.reset(index,curriculum.at_boundary(steps+count),data['seed']+steps+count+index)
                rows.append((observation,action,captured_starts,logprob,values,torch.tensor(rewards),torch.tensor(done)))
                if masks is not None: legal_rows.append(masks)
                starts=torch.tensor(done,dtype=torch.bool); steps+=count
            with torch.no_grad():
                _,bootstrap,_=policy.step(torch.tensor(np.stack(pool.observations),dtype=torch.float32),hidden,starts)
            columns=[torch.stack([row[i] for row in rows]) for i in range(7)]
            observation,action,episode_starts,logprob,values,rewards,dones=columns
            masks=[torch.stack([row[b] for row in legal_rows]) for b in range(len(policy.nvec))] if policy.nvec else None
            metrics=_ppo_update(policy,optimizer,(observation,action,episode_starts,masks,logprob,values,rewards,dones,bootstrap,initial),data['optimizer'])
            updates+=1; invocation_updates+=1
            run.append('running',phase='ppo-update',steps=steps,updates=updates,metrics=metrics,outcomes=ledger.snapshot(),curriculum=curriculum.snapshot())
            # T4 owns calibrated held-out evaluation. This due receipt never claims a pass.
            if steps-since_evaluation>=data['evaluation_every_steps']:
                run.append('running',phase='evaluation-due',steps=steps,qualified=None,reason='held-out evaluator required'); since_evaluation=steps
            stop=stop_after_updates is not None and invocation_updates>=stop_after_updates
            if steps-since_checkpoint>=data['checkpoint_every_steps'] or stop or steps>=data['total_steps'] or cancelled():
                checkpoint=TrainingCheckpoint.save(run,policy=policy,optimizer=optimizer,steps=steps,updates=updates,curriculum=curriculum.snapshot(),normalization=norm,config_hash=config.hash,source_pins=source_pins)
                run.append('running',phase='checkpoint',steps=steps,updates=updates,file=checkpoint.path.name,checkpoint_sha256=checkpoint.sha256,environment_restore='reset-boundary')
                since_checkpoint=steps
            if stop: break
        status='completed' if steps>=data['total_steps'] else 'cancelled'
        if checkpoint is None or checkpoint.steps!=steps:
            checkpoint=TrainingCheckpoint.save(run,policy=policy,optimizer=optimizer,steps=steps,updates=updates,curriculum=curriculum.snapshot(),normalization=norm,config_hash=config.hash,source_pins=source_pins)
        pool.close()
        if any(code!=0 for code in pool.exit_codes): raise RuntimeError('Worker cleanup failed')
        return run.append(status,steps=steps,updates=updates,checkpoint=checkpoint.path.name,checkpoint_sha256=checkpoint.sha256,worker_exit_codes=pool.exit_codes,workers_closed=pool.closed,policy_quality=None,numerical_reproducibility=False)
    except BaseException as error:
        pool.close()
        run.append('cancelled' if isinstance(error,KeyboardInterrupt) else 'failed',steps=steps,updates=updates,error=str(error)[:4096],workers_closed=pool.closed,worker_exit_codes=pool.exit_codes)
        raise
    finally:
        pool.close(); run.release()


TRAINERS['recurrent_ppo']=recurrent_ppo
