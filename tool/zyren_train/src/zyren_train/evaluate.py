"""Immutable held-out native task evaluation. Rewards never replace outcomes."""
from dataclasses import dataclass
from pathlib import Path
import hashlib,json
import numpy as np
import torch
from .scenario import ScenarioSpec,canonical_bytes,decode_json_bytes
from .train import TrainingConfig,worker_native_hashes
from .checkpoint import TrainingCheckpoint
from .gym_env import ZyrenEnv
from .policies.visual import create_policy
from .metrics import EpisodeMetric,aggregate
from .regression import TARGETS,qualify
from .report import EvaluationReport


@dataclass(frozen=True)
class EvaluationPlan:
    encoded: bytes
    @classmethod
    def from_dict(cls,value):
        if isinstance(value,dict) and value.get('schema_version')==2:
            from .multi_evaluation import validate_plan
            return cls(validate_plan(value))
        if set(value)-{'revision'}!={'schema_version','id','cases','paired_worlds','targets','training_scenario_hashes','worker_sha256','worker_native_sha256'} or value['schema_version']!=1 or type(value['schema_version']) is not int or value['targets']!=TARGETS: raise ValueError('Evaluation schema or immutable target changed')
        if not isinstance(value['id'],str) or not value['id'] or len(value['id'])>128 or not value['cases'] or len(value['cases'])>64: raise ValueError('Invalid evaluation identity/case budget')
        canonical_bytes(value)
        import re
        hashes=value['training_scenario_hashes']
        if not isinstance(hashes,list) or len(hashes)>1000 or len(set(hashes))!=len(hashes) or any(not isinstance(h,str) or not re.fullmatch('[0-9a-f]{64}',h) for h in hashes): raise ValueError('Training lineage pins differ')
        if 'revision' in value:
            revision=value['revision']
            content={key:value[key] for key in ('cases','paired_worlds','targets','training_scenario_hashes')}
            if (not isinstance(revision, dict)
                    or set(revision) != {'supersedes', 'reason', 'case_content_hash'}
                    or not isinstance(revision['supersedes'], str)
                    or not re.fullmatch('[0-9a-f]{64}', revision['supersedes'])
                    or revision['case_content_hash'] != hashlib.sha256(canonical_bytes(content)).hexdigest()):
                raise ValueError('Evaluation artifact revision lineage differs')
            if revision['reason'] == 'collision-only island and joint bookkeeping repair':
                if (revision['supersedes'] != 'deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd'
                        or revision['case_content_hash'] != 'b5a7eff352c517411b818b741e82c0a75bf330f254f78764fe2e43f307872f47'):
                    raise ValueError('Collision repair revision changed the locked structured suite')
            elif revision['reason'] != 'original executable overwritten during sequence-probe rebuild':
                raise ValueError('Evaluation artifact revision lineage differs')
        identifiers=set(); content=set(); schemas=set(); requested=0
        for case in value['cases']:
            if set(case)!={'id','family','scenario','seeds','stress','coverage'} or case['id'] in identifiers or case['family'] not in TARGETS: raise ValueError('Evaluation case identity differs')
            if not isinstance(case['id'],str) or not re.fullmatch('[A-Za-z0-9_-]{1,80}',case['id']): raise ValueError('Evaluation case identity differs')
            identifiers.add(case['id']); spec=ScenarioSpec.from_dict(case['scenario'])
            if spec.partition!='test' or spec.hash in value['training_scenario_hashes']: raise ValueError('Training/test scenario overlap')
            if spec.hash in content: raise ValueError('Duplicate held-out scenario content')
            content.add(spec.hash); schemas.add((case['family'],spec.observation_schema_hash,spec.action_schema_hash))
            seeds=case['seeds']
            if not isinstance(seeds,list) or not seeds or len(seeds)>2048 or any(type(seed) is not int or not 0<=seed<2**31 for seed in seeds): raise ValueError('Fixed episode seed list is invalid')
            requested+=len(seeds)
            if set(case['stress'])!={'miss_every','delay_every'} or any(type(n) is not int or not 0<=n<=10000 for n in case['stress'].values()): raise ValueError('Unknown decision stress')
            if not isinstance(case['coverage'],list) or len(case['coverage'])>16 or any(not isinstance(c,str) for c in case['coverage']): raise ValueError('Invalid stress provenance')
        if requested>2048 or any(len({p[1:] for p in schemas if p[0]==family})>1 for family in TARGETS): raise ValueError('Evaluation profile/budget differs')
        pair=value['paired_worlds']
        if set(pair)!={'left','right','seed','steps'} or type(pair['steps']) is not int or not 1<=pair['steps']<=240 or type(pair['seed']) is not int or not 0<=pair['seed']<2**31: raise ValueError('Paired-world plan differs')
        pair_specs=[ScenarioSpec.from_dict(pair[name]) for name in ('left','right')]
        if any(s.partition!='test' or s.hash in hashes for s in pair_specs) or pair_specs[0].hash==pair_specs[1].hash or any((s.observation_schema_hash,s.action_schema_hash)!=(pair_specs[0].observation_schema_hash,pair_specs[0].action_schema_hash) for s in pair_specs): raise ValueError('Paired worlds must remain held out with matching profiles')
        if not isinstance(value['worker_sha256'],str) or not re.fullmatch('[0-9a-f]{64}',value['worker_sha256']) or not isinstance(value['worker_native_sha256'],dict) or not value['worker_native_sha256']: raise ValueError('Evaluation artifact pins are missing')
        for name,digest in value['worker_native_sha256'].items():
            if not isinstance(name,str) or not name.startswith('lib/') or '..' in name.split('/') or '\\' in name or not isinstance(digest,str) or not re.fullmatch('[0-9a-f]{64}',digest): raise ValueError('Native artifact path/hash differs')
        return cls(canonical_bytes(value))
    @classmethod
    def load(cls,path): return cls.from_dict(decode_json_bytes(Path(path).read_bytes()))
    @property
    def data(self): return json.loads(self.encoded)
    @property
    def hash(self): return hashlib.sha256(self.encoded).hexdigest()
    @property
    def requested(self): return sum(len(case['seeds']) for case in self.data['cases'])


class PreparedEvaluationWorker:
    def __init__(self,command,cwd,plan): self.command=list(command);self.cwd=cwd;self.plan=plan
    def verify(self):
        actual={'worker_sha256':hashlib.sha256(Path(self.command[0]).read_bytes()).hexdigest(),'worker_native_sha256':worker_native_hashes(self.command[0])}
        self.artifact_after=actual
        if any(actual[key]!=self.plan.data[key] for key in actual):raise ValueError('Evaluation worker changed during run')
        return actual
    def __call__(self):
        from .worker import Worker
        self.artifact_before=self.verify()
        if len(self.command)!=1 or hashlib.sha256(Path(self.command[0]).read_bytes()).hexdigest()!=self.plan.data['worker_sha256'] or worker_native_hashes(self.command[0])!=self.plan.data['worker_native_sha256']: raise ValueError('Evaluation worker artifact bytes differ')
        return Worker(self.command,cwd=self.cwd,run_id=self.plan.hash[:24])


class StructuredCandidate:
    """Checkpoint actor bound to the deployed host schema, never metric fields."""
    def __init__(self,config,run):
        from types import SimpleNamespace
        self.config=config; self.checkpoint=TrainingCheckpoint.load(SimpleNamespace(path=Path(run)),config.hash)
        self.model_hash=self.checkpoint['_checkpoint_sha256']; self.provider=f'torch-{torch.__version__}-cpu'
        self.policy=None; self.state=None; self.started=True
        self.pins={(s['observation_schema_hash'],s['action_schema_hash']) for s in config.data['scenarios']}
    def reset(self): self.state=None;self.started=True
    def bind(self,info):
        if (info['observation_schema_hash'],info['action_schema_hash']) not in self.pins: raise ValueError('Model observation/action profile differs')
        width=sum(field['width'] for field in info['observation_schema']['fields'])
        action_space=info['action_space'];fallback=info['action_schema']['fallbackDiscrete']
        if self.policy is None:
            self.policy=create_policy(self.config.data.get('network',{'hidden_sizes':[128,128],'lstm_hidden_size':128}),width,action_space,observation_schema=info['observation_schema'],visual_profile=info.get('visual_profile'),fallback=fallback)
            self.policy.load_state_dict(self.checkpoint['model']);self.policy.eval()
        elif self.policy.width!=width or self.policy.action_space!=action_space or self.policy.fallback!=fallback: raise ValueError('Model host binding changed')
        if self.policy.distribution_id!=self.config.data['policy_distribution']: raise ValueError('Actor distribution binding differs')
    def act(self,observation,info):
        self.bind(info)
        if self.state is None:self.state=self.policy.initial_state(1)
        masks=[torch.tensor([branch],dtype=torch.bool) for branch in info['legality']] if self.policy.nvec else None
        with torch.no_grad():
            output,_,self.state=self.policy.step(torch.tensor(observation).unsqueeze(0),self.state,torch.tensor([self.started]))
            action=self.policy.distribution(output,masks).mode()[0].numpy()
        self.started=False;return action
    def hidden_snapshot(self): return None if self.state is None else tuple(value.detach().clone() for value in self.state)


class FamilyCandidate:
    """Independent guard and driver recurrent states, pinned as one evaluation."""
    def __init__(self,candidates):
        if set(candidates)!=set(TARGETS): raise ValueError('Both actor families required')
        self.candidates=dict(candidates);self.active=None
        self.family_model_hashes={family:c.model_hash for family,c in candidates.items()}
        self.model_hash=hashlib.sha256(canonical_bytes(self.family_model_hashes)).hexdigest()
        self.provider=';'.join(sorted({c.provider for c in candidates.values()}))
    def reset(self):
        self.active=None
        for candidate in self.candidates.values(): candidate.reset()
    def bind(self,info):
        family='guard' if info['action_space']['kind']=='multi_discrete' else 'vehicle'
        self.active=self.candidates[family];self.active.bind(info)
    def act(self,observation,info):
        self.bind(info);return self.active.act(observation,info)
    def hidden_snapshot(self): return self.active.hidden_snapshot()


class ScriptedCandidate:
    model_hash='scripted-v1';provider='native-scripted-v1'
    def reset(self): pass
    def bind(self,info): pass
    def act(self,observation,info):return np.asarray(info['baseline_action'],dtype=np.int64 if info['action_space']['kind']=='multi_discrete' else np.float32)
    def hidden_snapshot(self):return None


def decision_action(candidate,frame,current,*,missed=False):
    captured,receipt=frame
    # A delayed sensor receipt never commits recurrent state against a newer tick.
    if missed or any(receipt.get(key)!=current.get(key) for key in ('episode_id','tick','actor_generations','observation_schema_hash','action_schema_hash')):return _fallback(current)
    return candidate.act(captured,receipt)


def _fallback(info):
    schema=info['action_schema'];return np.asarray(schema['fallbackDiscrete'] if schema['branches'] else schema['fallbackContinuous'],dtype=np.int64 if schema['branches'] else np.float32)


def _verify(info,spec):
    actual=ScenarioSpec.from_dict(info['scenario_spec'])
    if actual.hash!=spec.hash or info['split']!='test' or info['build_id']!=spec.game_build_hash or info['observation_schema_hash']!=spec.observation_schema_hash or info['action_schema_hash']!=spec.action_schema_hash: raise ValueError('Held-out native world/schema/build pin differs')


def _paired(candidate,worker,plan):
    value=plan.data['paired_worlds']; worlds=[]; histories=[]
    try:
        for name in ('left','right'):
            spec=ScenarioSpec.from_dict(value[name]);env=ZyrenEnv(worker,environment_id='paired-'+name,scenario=spec.id,purpose='test',observation_width=None);worlds.append(env)
            observation,info=env.reset(seed=value['seed']);_verify(info,spec);candidate.reset();rows=[]
            for _ in range(value['steps']):
                action=candidate.act(observation,info); hidden=candidate.hidden_snapshot()
                rows.append((observation.copy(),action.copy(),hidden));observation,_,_,_,info=env.step(action)
                if info.get('worker_failed'):raise RuntimeError('Paired world worker failed')
            histories.append(rows)
        failures=0
        for left,right in zip(*histories):
            if not np.array_equal(left[0],right[0]) or not np.array_equal(left[1],right[1]): failures+=1;continue
            if left[2] is not None and (right[2] is None or any(not torch.equal(a,b) for a,b in zip(left[2],right[2]))):failures+=1
        return failures
    finally:
        for env in worlds:env.close()
        candidate.reset()


def _exploits(worker,plan,family):
    cases=[case for case in plan.data['cases'] if case['family']==family]
    case=cases[0];spec=ScenarioSpec.from_dict(case['scenario']); failures=0
    for attempt in ('stationary','oscillation'):
        env=ZyrenEnv(worker,environment_id='exploit-'+attempt,scenario=spec.id,purpose='test',observation_width=None)
        try:
            observation,info=env.reset(seed=case['seeds'][0]);_verify(info,spec);start=float(info['physics_position'][2]); reward=0.
            distance_basis=info.get('reward_progress_basis')=='remaining-distance-decrease'
            start_distance=float(info['task_remaining_distance']) if distance_basis else None
            for step in range(spec.to_dict()['max_steps']):
                action=_fallback(info)
                if attempt=='oscillation':
                    if info['action_schema']['branches']:
                        branches=info['action_schema']['branches'];index=next(i for i,b in enumerate(branches) if b['name']=='moveZ')
                        action[index]=branches[index]['choices'].index('positive' if step%40<20 else 'negative')
                    else: action=np.asarray([1. if step%40<20 else -1.,1.,0.],dtype=np.float32)
                observation,_,terminal,truncated,info=env.step(action)
                if info.get('worker_failed'):raise RuntimeError('Exploit worker failed')
                terms=info['reward_terms'];reward+=float(terms.get('task.progress',0))
                if any(abs(float(v))>next(term['cap'] for term in spec.to_dict()['reward_terms'] if term['id']==name) for name,v in terms.items()):failures+=1
                if terminal or truncated:break
            net=start_distance-float(info['task_remaining_distance']) if distance_basis else float(info['physics_position'][2])-start
            if abs(reward-net)>1e-4 or attempt=='stationary' and info['success']:failures+=1
        finally:env.close()
    return failures


def evaluate(model_bundle,plan,worker_factory,*,cancelled=lambda:False,auxiliary=True):
    if plan.data['schema_version']==2:
        from .multi_execution import evaluate_multi
        return evaluate_multi(model_bundle.candidates,plan,worker_factory,opponents=model_bundle.opponents,
            cancelled=cancelled,auxiliary=auxiliary)
    candidate=model_bundle; data=plan.data; episodes=[]; index=0;worker=None; failures=0; leaks=exploits=None;coverage=set(); evidence={}
    try:
        if cancelled():
            episodes=_missing_episodes(plan,'cancelled','cancelled before launch')
            return _finish(candidate,plan,episodes,0,None,None,set(),[],{})
        try: worker=worker_factory()
        except Exception as error:
            episodes=_missing_episodes(plan,'failed',str(error)[:1024])
            return _finish(candidate,plan,episodes,1,None,None,set(),[],{})
        for case in data['cases']:
            spec=ScenarioSpec.from_dict(case['scenario']);env=ZyrenEnv(worker,environment_id='eval-'+case['id'],scenario=spec.id,purpose='test',observation_width=None)
            try:
                for seed in case['seeds']:
                    observed=set();status='completed';success=collision=False;reward=progress=0.;steps=invalid=fallback=0;error=None
                    if cancelled():status='cancelled'
                    else:
                        try:
                            observation,info=env.reset(seed=seed);_verify(info,spec);candidate.reset();candidate.bind(info);previous_frame=None
                            for step in range(spec.to_dict()['max_steps']):
                                if cancelled():status='cancelled';break
                                stress=case['stress'];miss=stress['miss_every'] and (step+1)%stress['miss_every']==0;delayed=stress['delay_every'] and (step+1)%stress['delay_every']==0
                                frame=previous_frame if delayed and previous_frame is not None else (observation,info)
                                action=decision_action(candidate,frame,info,missed=bool(miss))
                                previous_frame=(observation.copy(),dict(info))
                                fallback+=int(bool(miss or delayed))
                                if miss: observed.add('missed-decisions')
                                if delayed: observed.add('delayed-observations')
                                observation,_,terminal,truncated,info=env.step(action);steps+=1
                                if info.get('worker_failed'):raise RuntimeError(info['error'])
                                if type(info.get('collision')) is not bool:raise ValueError('Native collision metric missing')
                                if info.get('task_mode')=='investigation': observed.add('occlusion-memory')
                                collision|=info['collision']; terms=info['reward_terms']
                                for name,term in terms.items():
                                    cap=next(t['cap'] for t in spec.to_dict()['reward_terms'] if t['id']==name)
                                    if not np.isfinite(term) or abs(term)>cap:raise ValueError('Native reward term exceeds cap')
                                reward+=sum(terms.values());progress+=terms.get('task.progress',0)
                                if terminal or truncated:success=bool(info['success']);break
                            else:raise RuntimeError('Native episode did not finish within pinned budget')
                        except Exception as problem:
                            status='failed';success=False;error=str(problem)[:1024]
                            invalid+=int(isinstance(problem,ValueError));failures+=1
                    if status=='completed':
                        settings=spec.settings
                        if settings.get('held_out_layout'): observed.add('unfamiliar-layouts')
                        if settings.get('friction_range'): observed.add('friction')
                        if settings.get('target_speed',0)>0: observed.add('moving-target')
                        if settings.get('curriculum_stage') in ('moving-hazards','task-combinations'): observed.add('moving-hazards')
                        if fallback: observed.add('fallback-recovery')
                        coverage.update(observed);evidence.setdefault(case['id'],set()).update(observed)
                    episodes.append(EpisodeMetric(index,seed,spec.id,case['family'],status,success,collision,float(reward),float(progress),steps,invalid,fallback,error));index+=1
            finally:env.close()
        if auxiliary and not cancelled():
            try: leaks=_paired(candidate,worker,plan);exploits=_exploits(worker,plan,'guard')+_exploits(worker,plan,'vehicle')
            except Exception:failures+=1
    finally:
        if worker is not None:
            worker.close()
            if hasattr(worker_factory,'verify'):
                try:worker_factory.verify()
                except Exception:failures+=1
    exits=[] if worker is None else [worker.process.returncode]
    return _finish(candidate,plan,episodes,failures,leaks,exploits,coverage,exits,{key:sorted(value) for key,value in evidence.items()})


def _missing_episodes(plan,status,error):
    rows=[]
    for case in plan.data['cases']:
        for seed in case['seeds']:
            rows.append(EpisodeMetric(len(rows),seed,case['scenario']['id'],case['family'],status,False,False,0.,0.,0,error=error))
    return rows


def _finish(candidate,plan,episodes,failures,leaks,exploits,coverage,exits,evidence):
    data=plan.data
    metrics={family:aggregate([e for e in episodes if e.family==family],sum(len(c['seeds']) for c in data['cases'] if c['family']==family)) for family in TARGETS if any(e.family==family for e in episodes)}
    status,reasons=qualify(metrics,hidden_state_leaks=leaks,reward_exploits=exploits,stress_coverage=coverage)
    seed_counts={family:len({e.seed for e in episodes if e.family==family}) for family in TARGETS}
    if any(count<20 for count in seed_counts.values()):status='failed';reasons.append('fewer than 20 held-out layout seeds')
    if failures or any(code!=0 for code in exits):status='failed';reasons.append('worker/evaluation failure')
    return EvaluationReport.from_dict({'schema_version':1,'plan':data,'plan_hash':plan.hash,'model_hash':candidate.model_hash,'family_model_hashes':getattr(candidate,'family_model_hashes',{f:candidate.model_hash for f in TARGETS}),'provider':candidate.provider,'status':status,'reasons':reasons,
        'requested':plan.requested,'metrics':metrics,'episodes':[e.to_dict() for e in episodes],'layout_seed_counts':seed_counts,
        'hidden_state_leaks':leaks,'reward_exploits':exploits,'stress_coverage':sorted(coverage),'coverage_evidence':evidence,'worker_failures':failures,'worker_exit_codes':exits,
        'worker_sha256':data['worker_sha256'],'worker_native_sha256':data['worker_native_sha256'],
        'stress_receipt':'delayed sensor frames and missed decisions rejected with shared fallback; hidden state does not advance'})


def compare_baseline(candidate,baseline):
    """Compare independent outcomes on exactly the same pinned episode slots."""
    left,right=candidate.data,baseline.data
    if left['plan_hash']!=right['plan_hash'] or left['requested']!=right['requested'] or left['worker_sha256']!=right['worker_sha256']: raise ValueError('Baseline plan/artifact differs')
    return {'schema_version':1,'plan_hash':left['plan_hash'],'candidate_report_hash':candidate.hash,'baseline_report_hash':baseline.hash,
            'candidate_status':left['status'],'baseline_status':right['status'],
            'families':{f:{'requested':left['metrics'][f]['requested'],'success_rate_delta':left['metrics'][f]['success_rate']-right['metrics'][f]['success_rate'],
                           'collision_rate_delta':left['metrics'][f]['collision_rate']-right['metrics'][f]['collision_rate'],
                           'reward_delta':left['metrics'][f]['reward_sum']-right['metrics'][f]['reward_sum']} for f in TARGETS}}


class OnnxCandidate:
    """Exact actor bytes evaluated with CPU ONNX Runtime and native controllers."""
    def __init__(self,directory):
        import onnxruntime as ort
        from .export import runtime_schema_hash
        folder=Path(directory);model=(folder/'actor.onnx').read_bytes();manifest=decode_json_bytes((folder/'model.json').read_bytes(),65536)
        self.model_hash=hashlib.sha256(model).hexdigest();self.provider=f'python-onnxruntime-{ort.__version__}-cpu'
        if manifest['sha256']!=self.model_hash or manifest['runtimeVersion']!=ort.__version__ or manifest['providers']!=['cpu']:raise ValueError('ONNX candidate artifact/provider differs')
        self.observation=decode_json_bytes((folder/'observation.json').read_bytes(),65536);self.action=decode_json_bytes((folder/'action.json').read_bytes(),65536)
        self.pins=(runtime_schema_hash(self.observation),runtime_schema_hash(self.action));self.width=sum(f['width'] for f in self.observation['fields']);self.nvec=[len(branch['choices']) for branch in self.action['branches']]
        self.session=ort.InferenceSession(model,providers=['CPUExecutionProvider']);self.state=None;self.reset()
    def reset(self):self.state=(np.zeros((1,128),dtype=np.float32),np.zeros((1,128),dtype=np.float32))
    def bind(self,info):
        if (info['observation_schema_hash'],info['action_schema_hash'])!=self.pins:raise ValueError('ONNX actor/controller profile differs')
    def act(self,observation,info):
        self.bind(info);observation=np.asarray(observation,dtype=np.float32).reshape(1,-1)
        if observation.shape!=(1,self.width):raise ValueError('ONNX actor width differs')
        values=self.session.run(None,{'observation':observation,'hidden':self.state[0],'cell':self.state[1]})
        if len(values)!=3 or any(not np.isfinite(v).all() for v in values):raise ValueError('Invalid ONNX actor output')
        scores,hidden,cell=values
        if hidden.shape!=(1,128) or cell.shape!=(1,128):raise ValueError('ONNX recurrent shape differs')
        if self.nvec:
            if scores.shape!=(1,sum(self.nvec)) or len(info['legality'])!=len(self.nvec):raise ValueError('ONNX logits/mask binding differs')
            choices=[];offset=0
            for size,mask,fallback in zip(self.nvec,info['legality'],self.action['fallbackDiscrete']):
                if len(mask)!=size or not all(type(value) is bool for value in mask) or not mask[fallback]:raise ValueError('ONNX legal fallback differs')
                choices.append(int(np.argmax(np.where(mask,scores[0,offset:offset+size],-np.finfo(np.float32).max))));offset+=size
            action=np.asarray(choices,dtype=np.int64)
        else:
            if scores.shape!=(1,len(self.action['continuous'])):raise ValueError('ONNX continuous head differs')
            action=scores[0].copy()
        self.state=(hidden,cell);return action
    def hidden_snapshot(self):return tuple(torch.tensor(value) for value in self.state)
