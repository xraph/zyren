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
