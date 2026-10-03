"""Generated-width MLP128,128 and LSTM128, with independent action contracts."""
import torch
from torch import nn
from .masked_recurrent import MaskedBranches, SquashedBox


class StructuredPolicy(nn.Module):
    def __init__(self,width,action_space,*,fallback=None,mean=None,scale=None):
        super().__init__()
        if type(width) is not int or not 1<=width<=16384: raise ValueError('Generated observation width is invalid')
        self.width=width; self.action_space=dict(action_space); self.fallback=list(fallback or [])
        if action_space['kind']=='multi_discrete':
            self.nvec=list(action_space['nvec']); outputs=sum(self.nvec)
            if not self.nvec or len(self.nvec)>128 or any(type(n) is not int or not 1<=n<=256 for n in self.nvec) or len(self.fallback)!=len(self.nvec): raise ValueError('Invalid branch schema')
        elif action_space['kind']=='box':
            outputs=len(action_space['low']); self.nvec=[]
            if not outputs or outputs>128: raise ValueError('Invalid continuous schema')
            self.log_std=nn.Parameter(torch.zeros(outputs))
        else: raise ValueError('Unknown policy head')
        self.register_buffer('observation_mean',torch.tensor(mean if mean is not None else [0.]*width,dtype=torch.float32))
        self.register_buffer('observation_scale',torch.tensor(scale if scale is not None else [1.]*width,dtype=torch.float32))
        if self.observation_mean.shape!=(width,) or self.observation_scale.shape!=(width,) or not torch.isfinite(self.observation_mean).all() or not torch.isfinite(self.observation_scale).all() or not (self.observation_scale>0).all(): raise ValueError('Invalid normalization')
        self.mlp=nn.Sequential(nn.Linear(width,128),nn.Tanh(),nn.Linear(128,128),nn.Tanh())
        self.lstm=nn.LSTMCell(128,128); self.action_head=nn.Linear(128,outputs); self.value_head=nn.Linear(128,1)
    def initial_state(self,batch):
        value=self.observation_mean.new_zeros((batch,128)); return value,value.clone()
    def step(self,observation,state,episode_starts):
        keep=(~episode_starts).to(observation.dtype).unsqueeze(-1)
        hidden,cell=self.lstm(self.mlp((observation-self.observation_mean)/self.observation_scale),(state[0]*keep,state[1]*keep))
        return self.action_head(hidden),self.value_head(hidden).squeeze(-1),(hidden,cell)
    def sequence(self,observations,episode_starts,*,state=None,valid=None):
        if observations.ndim!=3 or observations.shape[-1]!=self.width or episode_starts.shape!=observations.shape[:2] or not torch.isfinite(observations).all(): raise ValueError('Sequence schema differs')
        state=self.initial_state(observations.shape[1]) if state is None else state
        valid=torch.ones_like(episode_starts) if valid is None else valid
        if valid.shape!=episode_starts.shape or valid.dtype!=torch.bool: raise ValueError('Invalid padding mask')
        outputs=[]; values=[]
        for observation,starts,present in zip(observations,episode_starts,valid):
            output,value,next_state=self.step(observation,state,starts)
            state=tuple(torch.where(present[:,None],new,old) for new,old in zip(next_state,state))
            outputs.append(output); values.append(value)
        return torch.stack(outputs),torch.stack(values),state
    def distribution(self,output,masks=None):
        if self.nvec:
            if masks is None: raise ValueError('Captured legality masks are required')
            return MaskedBranches(output,self.nvec,masks,self.fallback)
        return SquashedBox(output,self.log_std,self.action_space['low'],self.action_space['high'])
