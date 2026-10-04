import torch
import numpy as np
import pytest
from zyren_train.policies.structured import StructuredPolicy
from zyren_train.self_play import SelfPlayActors,collect_parallel_rollout
from test_multi_agent import native_parallel


def test_recurrent_actor_states_are_independent_and_reset_by_episode():
    torch.manual_seed(7);torch.set_num_threads(1)
    policy=StructuredPolicy(4,{'kind':'multi_discrete','nvec':[3]},fallback=[1]).eval()
    actors=SelfPlayActors(policy)
    observations={'a':np.ones(4,dtype=np.float32),'b':np.zeros(4,dtype=np.float32)}
    infos={a:{'episode_id':'first','actor_generation':1,'legality':[[True]*3]} for a in observations}
    actors.act(observations,infos,deterministic=True)
    a=actors.states['a'][1][0].clone();b=actors.states['b'][1][0].clone()
    assert not torch.equal(a,b)
    isolated=SelfPlayActors(policy);isolated.act({'b':observations['b']},{'b':infos['b']},deterministic=True)
    assert torch.equal(b,isolated.states['b'][1][0])
    infos['a']['episode_id']='next'
    actors.act({'a':observations['a']},{'a':infos['a']},deterministic=True)
    assert 'b' not in actors.states and torch.equal(a,actors.states['a'][1][0])


def test_actual_native_shared_rollout_updates_policy_without_teacher_input(worker):
    from zyren_train.train import _ppo_update
    env=native_parallel(worker,'cooperative-search')
    try:
        obs,info=env.reset(seed=7)
        policy=StructuredPolicy(len(obs['a']),env._action_contract,fallback=[2,2,2,1,0,0])
        actors=SelfPlayActors(policy);before={k:v.clone() for k,v in policy.state_dict().items()}
        batch,obs,info,receipt=collect_parallel_rollout(env,actors,obs,info,steps=16,learners=['a','b'],reset_seed=7)
        optimizer=torch.optim.Adam(policy.parameters(),lr=.001)
        metrics=_ppo_update(policy,optimizer,batch,{'epochs':1,'gamma':.99,'gae_lambda':.95,'clip':.2,'entropy':.01,'value':.5,'max_grad_norm':.5})
        assert any(not torch.equal(v,before[k]) for k,v in policy.state_dict().items())
        assert receipt['native_steps']==16 and receipt['actor_transitions']==32
        assert receipt['completed_tick']==17 and receipt['training_only_actor_inputs']==0
        assert all(np.isfinite(v) for v in metrics.values())
    finally:env.close()


class ShortEpisode:
    def __init__(self):
        self.resets=0;self.agents=['a','b'];self._header={'tick':1}
    def reset(self,seed):
        self.resets+=1;self.agents=['a','b'];self._header={'tick':1}
        return self.inputs()
    def inputs(self):
        obs={a:np.zeros(4,dtype=np.float32) for a in ['a','b']}
        info={a:{'episode_id':str(self.resets),'actor_generation':1,'legality':[[True]*3]} for a in obs}
        return obs,info
    def step(self,actions):
        self._header['tick']+=1
        ended=self._header['tick']==3
        if ended:self.agents=[]
        obs,info=self.inputs()
        return obs,{a:1. for a in obs},{a:ended for a in obs},{a:False for a in obs},info


def test_episode_boundary_rollout_does_not_start_an_untrained_partial_episode():
    policy=StructuredPolicy(4,{'kind':'multi_discrete','nvec':[3]},fallback=[1])
    env=ShortEpisode();obs,infos=env.reset(seed=7)
    batch,obs,infos,receipt=collect_parallel_rollout(env,SelfPlayActors(policy),obs,infos,
        steps=8,learners=['a','b'],reset_seed=9,stop_at_episode_boundary=True)
    assert env.resets==1 and env.agents==[]
    assert receipt['native_steps']==2 and receipt['actor_transitions']==4 and receipt['completed_tick']==3
    assert batch[0].shape[:2]==(2,2) and batch[7][-1].all() and torch.equal(batch[8],torch.zeros(2))


def test_final_single_step_budget_preserves_live_bootstrap():
    policy=StructuredPolicy(4,{'kind':'multi_discrete','nvec':[3]},fallback=[1])
    env=ShortEpisode();obs,infos=env.reset(seed=7)
    batch,_,_,receipt=collect_parallel_rollout(env,SelfPlayActors(policy),obs,infos,
        steps=1,learners=['a','b'],reset_seed=9,stop_at_episode_boundary=True)
    assert receipt['native_steps']==1 and receipt['episodes']==0 and env.resets==1
    assert not batch[7][-1].any() and torch.isfinite(batch[8]).all()
