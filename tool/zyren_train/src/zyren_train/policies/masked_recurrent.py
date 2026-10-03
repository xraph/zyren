"""Explicit masked discrete and transformed continuous policy densities."""
import torch
from torch.distributions import Categorical, Normal


def mask_logits(logits,nvec,masks):
    """Finite masked scores used by training and the ONNX deployment adapter."""
    segments=[]; offset=0
    for size,mask in zip(nvec,masks):
        segments.append(logits[...,offset:offset+size].masked_fill(~mask,torch.finfo(logits.dtype).min))
        offset+=size
    return torch.cat(segments,dim=-1)


class MaskedBranches:
    def __init__(self, logits, nvec, masks, fallback):
        if logits.shape[-1]!=sum(nvec) or len(masks)!=len(nvec) or len(fallback)!=len(nvec):
            raise ValueError('Action branches differ')
        if not torch.isfinite(logits).all(): raise ValueError('Nonfinite policy logits')
        self.distributions=[]; self.masks=[]; offset=0
        self.masked_logits=mask_logits(logits,nvec,masks)
        for size,mask,legal_fallback in zip(nvec,masks,fallback):
            if mask.dtype!=torch.bool or mask.shape!=logits.shape[:-1]+(size,) or not 0<=legal_fallback<size or not mask[...,legal_fallback].all():
                raise ValueError('Every branch requires its legal fallback')
            values=self.masked_logits[...,offset:offset+size]
            self.distributions.append(Categorical(logits=values)); self.masks.append(mask); offset+=size
    def sample(self): return torch.stack([d.sample() for d in self.distributions],dim=-1)
    def mode(self): return torch.stack([d.logits.argmax(-1) for d in self.distributions],dim=-1)
    def log_prob(self,actions):
        if actions.shape!=self.distributions[0].batch_shape+(len(self.distributions),) or actions.dtype!=torch.long:
            raise ValueError('Discrete actions must retain integral branch identity')
        value=sum(d.log_prob(actions[...,i]) for i,d in enumerate(self.distributions))
        legal=torch.stack([mask.gather(-1,actions[...,i:i+1]).squeeze(-1) for i,mask in enumerate(self.masks)]).all(0)
        return value.masked_fill(~legal,-torch.inf)
    def entropy(self): return sum(d.entropy() for d in self.distributions)


class SquashedBox:
    def __init__(self,mean,log_std,low,high):
        self.low=torch.as_tensor(low,dtype=mean.dtype,device=mean.device)
        self.high=torch.as_tensor(high,dtype=mean.dtype,device=mean.device)
        if mean.shape[-1]!=len(low) or len(low)!=len(high) or not (self.low<self.high).all(): raise ValueError('Continuous bounds differ')
        self.scale=(self.high-self.low)/2; self.center=(self.high+self.low)/2
        self.normal=Normal(mean,log_std.clamp(-5,2).exp())
    def sample(self): return self.center+self.scale*torch.tanh(self.normal.sample())
    def mode(self): return self.center+self.scale*torch.tanh(self.normal.mean)
    def log_prob(self,actions):
        if actions.shape!=self.normal.mean.shape or not torch.isfinite(actions).all() or (actions<self.low).any() or (actions>self.high).any():
            raise ValueError('Continuous action outside shared bounds')
        value=((actions-self.center)/self.scale).clamp(-1+1e-6,1-1e-6)
        latent=torch.atanh(value)
        return (self.normal.log_prob(latent)-torch.log(self.scale)-torch.log1p(-value.square())).sum(-1)
    def entropy(self):
        # Monte Carlo entropy of the transformed distribution, including Jacobian.
        return -self.log_prob(self.sample())
