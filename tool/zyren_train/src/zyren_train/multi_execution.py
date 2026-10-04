"""Execute v2 slots through the shared native worker and private actor memories."""
import hashlib
import re
import math
import inspect
import numpy as np
import torch
from .scenario import ScenarioSpec, canonical_bytes
from .pettingzoo_env import ZyrenParallelEnv
from .metrics import EpisodeMetric, aggregate
from .regression import qualify_multi
from .report import EvaluationReport


class StaleMultiReceipt(ValueError):
    pass


class MultiFamilyCandidate:
    def __init__(self,candidates,opponents):
        self.candidates=dict(candidates);self.opponents=dict(opponents)


class MultiPolicyActor:
    def __init__(self,policy,*,model_hash,config_hash,observation_hash,action_hash,provider=None):
        self.policy=policy.eval();self.model_hash=model_hash;self.config_hash=config_hash
        self.observation_hash=observation_hash;self.action_hash=action_hash
        self.provider=provider or f'torch-{torch.__version__}-cpu';self.states={}
    def reset(self):self.states.clear()
    def act(self,actor,observation,info):
        if not isinstance(actor,str) or not re.fullmatch('[A-Za-z0-9_.:/-]{1,256}',actor) or actor not in self.states and len(self.states)>=64:
            raise ValueError('Multi actor identity budget exceeded')
        if not isinstance(info,dict) or any(type(info.get(k)) is not int or info[k]<1 for k in ('tick','actor_generation')) or not isinstance(info.get('episode_id'),str):
            raise ValueError('Multi actor receipt identity differs')
        allowed={'tick','episode_id','actor_generation','observation_schema_hash','action_schema_hash','build_id','legality'}
        if set(info)-allowed or (info['observation_schema_hash'],info['action_schema_hash'])!=(self.observation_hash,self.action_hash):
            raise ValueError('Actor-only multi observation identity differs')
        identity=(info['episode_id'],info['actor_generation'])
        saved=self.states.get(actor);start=saved is None or saved[0]!=identity
        if not start and info['tick']<=saved[2]:raise StaleMultiReceipt('Stale multi actor receipt')
        state=self.policy.initial_state(1) if start else saved[1]
        value=np.asarray(observation,dtype=np.float32)
        if value.shape!=(self.policy.width,) or not np.isfinite(value).all():raise ValueError('Multi actor tensor differs')
        masks=[torch.tensor([branch],dtype=torch.bool) for branch in info['legality']]
        with torch.no_grad():
            scores,_,state=self.policy.step(torch.from_numpy(value).unsqueeze(0),state,torch.tensor([start]))
            action=self.policy.distribution(scores,masks).mode()[0].numpy().copy()
        self.states[actor]=(identity,tuple(v.detach().clone() for v in state),info['tick'])
        return action
    def hidden_snapshot(self,actor):
        saved=self.states.get(actor)
        return None if saved is None else tuple(v.clone() for v in saved[1])


class MultiFixedActor:
    """Frozen idle or permitted-observation route/chase comparison controller."""
    def __init__(self,mode,*,observation_hash,action_hash):
        if mode not in ('stationary','observed-route'):raise ValueError('Unknown frozen multi baseline')
        self.mode=mode;self.observation_hash=observation_hash;self.action_hash=action_hash;self.states={}
        config={'version':1,'mode':mode,'observation_hash':observation_hash,'action_hash':action_hash,
                'yaw':'last applied world movement','target':'single visible opponent','jump':False,'interact':False}
        self.config_hash=hashlib.sha256(canonical_bytes(config)).hexdigest()
        self.model_hash=hashlib.sha256(inspect.getsource(type(self)).encode()+canonical_bytes(config)).hexdigest()
        self.provider='scripted-permitted-multi-v1'
    def reset(self):self.states.clear()
    def hidden_snapshot(self,actor):return None
    def act(self,actor,observation,info):
        allowed={'tick','episode_id','actor_generation','observation_schema_hash','action_schema_hash','build_id','legality'}
        if not isinstance(info,dict) or set(info)-allowed or (info.get('observation_schema_hash'),info.get('action_schema_hash'))!=(self.observation_hash,self.action_hash):
            raise ValueError('Frozen actor-only input differs')
        if not isinstance(actor,str) or not re.fullmatch('[A-Za-z0-9_.:/-]{1,256}',actor) or actor not in self.states and len(self.states)>=64:
            raise ValueError('Frozen actor identity budget differs')
        if any(type(info.get(k)) is not int or info[k]<1 for k in ('tick','actor_generation')) or not isinstance(info.get('episode_id'),str):
            raise ValueError('Frozen receipt identity differs')
        identity=(info['episode_id'],info['actor_generation']);saved=self.states.get(actor)
        heading=0. if saved is None or saved[0]!=identity else saved[1]
        if saved is not None and saved[0]==identity and info['tick']<=saved[2]:raise StaleMultiReceipt('Frozen actor receipt is stale')
        value=np.asarray(observation,dtype=np.float32)
        if value.shape!=(36,) or not np.isfinite(value).all():raise ValueError('Frozen actor tensor differs')
        x=z=0.
        if self.mode=='observed-route':
            if value[29]==1:x,z=float(value[27])*15,float(value[28])*15
            elif np.all(value[17:20]==1):
                local_x,local_z=float(value[4])*15,float(value[6])*15
                x=local_x*math.cos(heading)+local_z*math.sin(heading)
                z=-local_x*math.sin(heading)+local_z*math.cos(heading)
        length=math.hypot(x,z)
        if length<.4:x=z=0.
        else:x/=length;z/=length
        bins=(-1.,-.5,0.,.5,1.)
        action=np.asarray([min(range(5),key=lambda i:abs(bins[i]-x)),min(range(5),key=lambda i:abs(bins[i]-z)),2,1,0,0],dtype=np.int64)
        legality=info['legality']
        if len(legality)!=6 or any(len(branch)!=n or not branch[choice] for branch,n,choice in zip(legality,(5,5,5,3,2,2),action)):
            raise ValueError('Frozen typed action is not legal')
        move_x,move_z=bins[int(action[0])],bins[int(action[1])]
        if move_x or move_z:heading=math.atan2(move_x,move_z)
        self.states[actor]=(identity,heading,info['tick'])
        return action


def _env(worker,spec,name):
    return ZyrenParallelEnv(worker,scenario=spec.id,possible_agents=['a','b'],observation_width=36,
        action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},environment_id=name,purpose='test')


def _verify(env,spec):
    h=env._header
    if ScenarioSpec.from_dict(h['scenario_spec']).hash!=spec.hash or h.get('physics_backend')!='rapier' or h.get('split')!='test':
        raise ValueError('Pinned native multi scenario differs')


def _slot(worker,case,seed,candidate,opponent,index,cancelled,*,environment_factory=None,verify=None):
    spec=ScenarioSpec.from_dict(case['scenario']);env=(environment_factory or _env)(worker,spec,'multi-'+case['id'])
    verify=verify or _verify
    steps=invalid=stale=0;collision=False;reward=0.;result='loss';status='completed';error=None
    totals={};initial=None;last=None
    try:
        observations,infos=env.reset(seed=seed);verify(env,spec)
        candidate.reset()
        if opponent is not None:opponent.reset()
        initial=dict(env.training_only['distances'])
        while env.agents and steps<spec.max_steps:
            if cancelled():status='cancelled';break
            actions={}
            roles=env._header['task_roles']
            for actor in env.agents:
                owner=candidate if case['role']=='joint' or roles[actor]==case['role'] else opponent
                actions[actor]=owner.act(actor,observations[actor],infos[actor])
            observations,rewards,terminated,truncated,infos=env.step(actions);steps+=1
            verify(env,spec);h=env._header
            if type(h.get('collision')) is not bool:raise ValueError('Native contact outcome missing')
            collision|=h['collision']
            applied=h.get('applied_actions')
            if not isinstance(applied,dict) or any(a not in applied or not np.array_equal(v,applied[a]) for a,v in actions.items()):
                invalid+=1;raise ValueError('Fresh typed controller rejected an evaluated action')
            for a,value in rewards.items():
                if not np.isfinite(value) or abs(value)>1:raise ValueError('Native multi reward cap exceeded')
                totals[a]=totals.get(a,0.)+value
                if case['role']=='joint' or roles[a]==case['role']:reward+=value
            last=dict(env.training_only['distances'])
        if status=='completed':
            if env.agents:raise RuntimeError('Native joint episode exceeded its pinned horizon')
            outcomes=env._header.get('per_agent_results');roles=env._header['task_roles']
            if not isinstance(outcomes,dict) or set(outcomes)!=set(roles):raise ValueError('Native role results missing')
            if case['role']=='joint':
                if len(set(outcomes.values()))!=1:raise ValueError('Cooperative credit is not joint')
                result=next(iter(outcomes.values()))
            else:
                byrole={roles[a]:outcomes[a] for a in roles}
                if byrole not in ({'pursuer':'win','evader':'loss'},{'pursuer':'loss','evader':'win'},{'pursuer':'draw','evader':'draw'}):raise ValueError('Competitive credit is not exclusive')
                result=byrole[case['role']]
    except Exception as problem:
        status='failed';result='loss';error=str(problem)[:1024];invalid+=int(isinstance(problem,ValueError));stale+=int(isinstance(problem,StaleMultiReceipt))
    finally:env.close()
    reward_fault=0
    if status=='completed':
        for a,total in totals.items():
            expected=(last[a]-initial[a]) if case['family']=='competitive-pursuit' and a=='b' else (initial[a]-last[a])
            reward_fault+=int(abs(total-expected)>1e-4)
    return EpisodeMetric(index,seed,spec.id,case['family'],status,result=='win',collision,reward,reward,steps,
        invalid_actions=invalid,error=error,role=case['role'],result=result,opponent=case['opponent']),reward_fault,stale


def _paired(worker,plan,candidates):
    failures=0
    for pair in plan.data['paired_worlds']:
        candidate=candidates[pair['family']];histories=[]
        for side in ('left','right'):
            spec=ScenarioSpec.from_dict(pair[side]);env=_env(worker,spec,'paired-'+pair['family']+'-'+side)
            try:
                observations,infos=env.reset(seed=pair['seed']);_verify(env,spec);candidate.reset();rows=[]
                for _ in range(pair['steps']):
                    actions={a:candidate.act(a,observations[a],infos[a]) for a in env.agents}
                    rows.append({a:(observations[a].copy(),actions[a].copy(),candidate.hidden_snapshot(a)) for a in pair['actors']})
                    observations,_,_,_,infos=env.step(actions)
                histories.append(rows)
            finally:env.close()
        for left,right in zip(*histories):
            for actor in pair['actors']:
                a,b=left[actor],right[actor]
                failures+=int(not np.array_equal(a[0],b[0]) or not np.array_equal(a[1],b[1]) or
                    (a[2] is None)!=(b[2] is None) or a[2] is not None and any(not np.array_equal(x,y) for x,y in zip(a[2],b[2])))
        candidate.reset()
    return failures


def evaluate_multi(candidates,plan,worker_factory,*,opponents,cancelled=lambda:False,auxiliary=True):
    data=plan.data
    if data['schema_version']!=2 or set(candidates)!=set(data['multi_profiles']) or set(opponents)!={o['id'] for o in data['opponents']}:
        raise ValueError('Exact multi families and opponent catalog required')
    for o in data['opponents']:
        actual=opponents[o['id']]
        if actual.model_hash!=o['policy_hash'] or actual.config_hash!=o['config_hash']:raise ValueError('Frozen multi opponent bytes differ')
    rows=[];worker=None;failures=stale_outputs=0;exploits=leaks=None;exits=[]
    try:
        if not cancelled():worker=worker_factory();exploits=0
        for case in data['cases']:
            for seed in case['seeds']:
                if cancelled() or worker is None:
                    row=EpisodeMetric(len(rows),seed,case['scenario']['id'],case['family'],
                        'cancelled' if cancelled() else 'failed',False,False,0.,0.,0,
                        role=case['role'],result='loss',opponent=case['opponent'])
                else:
                    row,fault,stale=_slot(worker,case,seed,candidates[case['family']],opponents.get(case['opponent']),len(rows),cancelled)
                    exploits+=fault;stale_outputs+=stale;failures+=int(row.status=='failed')
                rows.append(row)
        if worker is not None and auxiliary and not cancelled():
            try:leaks=_paired(worker,plan,candidates)
            except Exception:failures+=1
    except Exception:
        failures+=1
        slots=[(s,c) for c in data['cases'] for s in c['seeds']]
        for seed,case in slots[len(rows):]:
            rows.append(EpisodeMetric(len(rows),seed,case['scenario']['id'],case['family'],'failed',False,False,0.,0.,0,
                role=case['role'],result='loss',opponent=case['opponent']))
    finally:
        if worker is not None:
            worker.close();exits=[worker.process.returncode]
        if hasattr(worker_factory,'verify'):worker_factory.verify()
    joint=[r for r in rows if r.family=='cooperative-search'];coop=aggregate(joint,len(joint))
    roles={};heldout={};history={};history_roles={}
    for role in ('pursuer','evader'):
        heldout[role]={};history[role]={};groups={'heldout':[],'historical':[]}
        for o in data['opponents']:
            group=[r for r in rows if r.role==role and r.opponent==o['id']]
            phase='historical' if o['kind']=='historical' else 'heldout';groups[phase].extend(group)
            (history if phase=='historical' else heldout)[role][o['id']]=aggregate(group,len(group))
        roles[role]=aggregate(groups['heldout'],len(groups['heldout']))
        history_roles[role]=aggregate(groups['historical'],len(groups['historical']))
    previous=data['previous_checkpoint'];status,reasons=qualify_multi(coop,roles,heldout,
        hidden_state_leaks=leaks,reward_exploits=exploits,worker_failures=failures,stale_outputs=stale_outputs,
        historical=history,previous=None if previous is None else previous['role_win_rates'],initial_baseline=data['initial_baseline'])
    if not exits or any(code!=0 for code in exits):reasons.append('worker close evidence missing or failed');status='failed'
    heldout_ids={o['id'] for o in data['opponents'] if o['kind']!='historical'}
    seeds={'cooperative-search':len({r.seed for r in joint}),'competitive-pursuit':{
        role:len({r.seed for r in rows if r.role==role and r.opponent in heldout_ids}) for role in roles}}
    if seeds['cooperative-search']<20 or any(n<20 for n in seeds['competitive-pursuit'].values()):reasons.append('held-out layout seeds too few');status='failed'
    if any(r.status=='completed' and r.steps<1 for r in rows):reasons.append('native task execution missing');status='failed'
    models={f:c.model_hash for f,c in candidates.items()}
    return EvaluationReport.from_dict({'schema_version':2,'plan':data,'plan_hash':plan.hash,
        'model_hash':hashlib.sha256(canonical_bytes(models)).hexdigest(),'family_model_hashes':models,
        'role_model_hashes':{r:models['competitive-pursuit'] for r in roles},
        'provider':';'.join(sorted({c.provider for c in candidates.values()})),
        'status':status,'reasons':reasons,'requested':plan.requested,
        'metrics':{'cooperative-search':coop,'competitive-pursuit':roles},
        'episodes':[r.to_dict() for r in rows],'opponent_metrics':heldout,'historical_metrics':history,
        'historical_role_metrics':history_roles,'layout_seed_counts':seeds,'hidden_state_leaks':leaks,
        'reward_exploits':exploits,'stale_outputs':stale_outputs,'worker_failures':failures,'worker_exit_codes':exits,
        'worker_sha256':data['worker_sha256'],'worker_native_sha256':data['worker_native_sha256']})
