import torch
import pytest
from zyren_train.policies.masked_recurrent import MaskedBranches, SquashedBox


def test_fallback_only_sampling_logprob_entropy_share_masks():
    logits=torch.randn(4,22,requires_grad=True)
    masks=[torch.zeros(4,n,dtype=torch.bool) for n in [5,5,5,3,2,2]]
    fallback=[2,2,2,1,0,0]
    for mask,index in zip(masks,fallback): mask[:,index]=True
    distribution=MaskedBranches(logits,[5,5,5,3,2,2],masks,fallback)
    action=distribution.sample()
    assert action.tolist()==[fallback]*4
    assert torch.equal(distribution.log_prob(action),torch.zeros(4))
    assert torch.allclose(distribution.entropy(),torch.zeros(4))
    illegal=action.clone(); illegal[:,0]=0
    assert torch.isneginf(distribution.log_prob(illegal)).all()
    distribution.log_prob(action).sum().backward()
    assert torch.isfinite(logits.grad).all()
    masks[0][:]=False
    with pytest.raises(ValueError): MaskedBranches(logits,[5,5,5,3,2,2],masks,fallback)


def test_continuous_bounded_samples_have_finite_same_density():
    box=SquashedBox(torch.zeros(64,3),torch.zeros(3),[-1,0,0],[1,1,1])
    actions=box.sample()
    assert (actions[:,0]>=-1).all() and (actions[:,1:]>=0).all() and (actions<=1).all()
    assert torch.isfinite(box.log_prob(actions)).all()
    assert torch.isfinite(box.entropy()).all()


def test_export_masked_scores_match_training_mode_and_stay_finite():
    from zyren_train.policies.masked_recurrent import mask_logits
    logits=torch.tensor([[100.,2.,3.,100.,7.]])
    masks=[torch.tensor([[False,True,True]]),torch.tensor([[False,True]])]
    scores=mask_logits(logits,[3,2],masks)
    distribution=MaskedBranches(logits,[3,2],masks,[1,1])
    assert torch.equal(scores,distribution.masked_logits)
    assert distribution.mode().tolist()==[[2,1]] and torch.isfinite(scores).all()


def test_censored_brake_zero_mass_and_boundary_tails_are_finite():
    from zyren_train.policies.masked_recurrent import CensoredBox
    torch.manual_seed(7)
    mean=torch.tensor([[0.,.8,-.2]]*1024,requires_grad=True)
    distribution=CensoredBox(mean,torch.zeros(3),[-1,0,0],[1,1,1])
    actions=distribution.sample()
    assert ((actions[:,1]>0)&(actions[:,2]==0)).any()
    assert ((actions[:,1]>0)&(actions[:,2]>0)).any()
    endpoints=torch.tensor([[-1.,0.,0.],[1.,1.,1.]])
    tails=CensoredBox(torch.zeros(2,3),torch.zeros(3),[-1,0,0],[1,1,1]).log_prob(endpoints)
    assert torch.isfinite(tails).all()
    assert torch.allclose(tails[0],torch.special.log_ndtr(torch.tensor(-1.))+2*torch.special.log_ndtr(torch.tensor(0.)))
    entropy=distribution.entropy()
    assert torch.isfinite(distribution.log_prob(actions)).all() and torch.isfinite(entropy).all()
    entropy.mean().backward(); assert torch.isfinite(mean.grad).all()
