"""Behavior cloning consumes only verified training partition sequences."""
import torch
from ..dataset import DatasetPartition


def cloning_loss(policy,observations,actions,episode_starts,masks,valid):
    if not valid.any(): raise ValueError('Empty cloning sequence')
    outputs,_,_=policy.sequence(observations,episode_starts,valid=valid)
    if policy.nvec:
        loss=-policy.distribution(outputs,masks).log_prob(actions)
    else:
        predicted=policy.distribution(outputs).mode()
        loss=(predicted-actions).square().mean(-1)
    return loss[valid].mean()


def training_sequences(partition,policy,max_rows=1_000_000):
    if not isinstance(partition,DatasetPartition) or partition.name!='train' or not partition.recordings: raise ValueError('Verified training recordings are required')
    # Force source membership/hash checks before optimization can begin.
    for _ in partition.observation_samples(): pass
    total=0
    for path,manifest in partition.recordings:
        observations=[]; actions=[]; masks=[]; current=None
        for row in manifest.records(path):
            if len(row['observations'])!=1: raise ValueError('Single actor cloning requires one actor')
            if current is not None and row['episode_id']!=current: raise ValueError('Missing cloning episode boundary')
            current=row['episode_id']; actor=next(iter(row['observations']))
            applied=row['applied_actions'][actor]
            if policy.nvec and (len(applied)!=len(policy.nvec) or any(value!=int(value) or not 0<=value<size for value,size in zip(applied,policy.nvec))): raise ValueError('Cloning discrete action violates branch schema')
            if not policy.nvec and (len(applied)!=len(policy.action_space['low']) or any(not low<=value<=high for value,low,high in zip(applied,policy.action_space['low'],policy.action_space['high']))): raise ValueError('Cloning continuous action violates bounds')
            if len(observations)>=1024: raise ValueError('Cloning sequence exceeds memory budget')
            observations.append(row['observations'][actor]); actions.append(applied)
            if policy.nvec: masks.append(row['legality'][actor])
            total+=1
            if total>max_rows: raise ValueError('Cloning row budget exceeded')
            if row['terminated'] or row['truncated']:
                obs=torch.tensor(observations,dtype=torch.float32).unsqueeze(1)
                act=torch.tensor(actions,dtype=torch.long if policy.nvec else torch.float32).unsqueeze(1)
                starts=torch.zeros(obs.shape[:2],dtype=torch.bool); starts[0]=True
                legal=[torch.tensor([m[b] for m in masks],dtype=torch.bool).unsqueeze(1) for b in range(len(policy.nvec))] if policy.nvec else None
                yield obs,act,starts,legal,torch.ones_like(starts)
                observations=[]; actions=[]; masks=[]; current=None
