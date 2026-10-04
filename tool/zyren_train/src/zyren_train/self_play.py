"""Independent recurrent actors on the shared native parallel environment."""
import numpy as np
import torch
from .train import _masks


class SelfPlayActors:
    def __init__(self,policy,*,frozen=None):
        self.policy=policy;self.frozen=dict(frozen or {});self.states={}
        if len(self.frozen)>64 or any(p is policy or any(v.requires_grad for v in p.parameters()) for p in self.frozen.values()):raise ValueError('Opponent policies must be separate frozen weights')
    def state_for(self,actor,info):
        identity=(info['episode_id'],info['actor_generation'])
        saved=self.states.get(actor)
        policy=self.frozen.get(actor,self.policy)
        return (saved[1] if saved is not None and saved[0]==identity else policy.initial_state(1)),saved is None or saved[0]!=identity
    def act(self,observations,infos,*,deterministic=False):
        if not observations or set(observations)!=set(infos) or len(observations)>64:raise ValueError('Live actor inputs differ')
        self.states={a:v for a,v in self.states.items() if a in observations}
        actions={};records={}
        for actor in sorted(observations):
            policy=self.frozen.get(actor,self.policy);state,start=self.state_for(actor,infos[actor])
            initial=tuple(v.detach().clone() for v in state)
            observation=torch.as_tensor(observations[actor],dtype=torch.float32).reshape(1,-1)
            masks=_masks([infos[actor]],policy.nvec)
            with torch.no_grad():
                scores,value,next_state=policy.step(observation,state,torch.tensor([start]))
                distribution=policy.distribution(scores,masks)
                action=distribution.mode() if deterministic or actor in self.frozen else distribution.sample()
                logprob=distribution.log_prob(action)
            self.states[actor]=((infos[actor]['episode_id'],infos[actor]['actor_generation']),tuple(v.detach() for v in next_state))
            actions[actor]=action[0].numpy().copy()
            records[actor]={'observation':observation[0],'action':action[0],'start':start,'masks':masks,'logprob':logprob[0],'value':value[0],'initial':initial}
        return actions,records


def collect_parallel_rollout(env,actors,observations,infos,*,steps,learners,reset_seed):
    if type(steps) is not int or not 2<=steps<=256 or not 1<=len(learners)<=64 or len(set(learners))!=len(learners) or set(learners)&set(actors.frozen):raise ValueError('Parallel rollout budget differs')
    learners=list(learners);rows=[];mask_rows=[];episodes=0
    initial=tuple(torch.cat([actors.state_for(a,infos[a])[0][i] for a in learners],dim=0).detach().clone() for i in range(2))
    for index in range(steps):
        live={a:observations[a] for a in env.agents};live_info={a:infos[a] for a in env.agents}
        if not set(learners)<=set(live):raise ValueError('A learner left this bounded rollout')
        actions,records=actors.act(live,live_info)
        next_observations,rewards,terminated,truncated,next_infos=env.step(actions)
        selected=[records[a] for a in learners]
        rows.append((torch.stack([r['observation'] for r in selected]),torch.stack([r['action'] for r in selected]),torch.tensor([r['start'] for r in selected]),torch.stack([r['logprob'] for r in selected]),torch.stack([r['value'] for r in selected]),torch.tensor([rewards[a] for a in learners],dtype=torch.float32),torch.tensor([terminated[a] or truncated[a] for a in learners])))
        if actors.policy.nvec:mask_rows.append([torch.cat([r['masks'][b] for r in selected],dim=0) for b in range(len(actors.policy.nvec))])
        observations,infos=next_observations,next_infos
        if not set(learners)<=set(env.agents):
            episodes+=1;observations,infos=env.reset(seed=reset_seed+episodes)
    hidden=tuple(torch.cat([actors.state_for(a,infos[a])[0][i] for a in learners],dim=0) for i in range(2))
    starts=torch.tensor([actors.state_for(a,infos[a])[1] for a in learners])
    with torch.no_grad():_,bootstrap,_=actors.policy.step(torch.tensor(np.stack([observations[a] for a in learners])),hidden,starts)
    obs,action,start,logprob,value,reward,done=[torch.stack([row[i] for row in rows]) for i in range(7)]
    masks=[torch.stack([row[b] for row in mask_rows]) for b in range(len(actors.policy.nvec))] if actors.policy.nvec else None
    batch=(obs,action,start,masks,logprob,value,reward,done,bootstrap,initial)
    receipt={'native_steps':steps,'actor_transitions':steps*len(learners),'episodes':episodes,'completed_tick':env._header['tick'],'training_only_actor_inputs':0}
    return batch,observations,infos,receipt
