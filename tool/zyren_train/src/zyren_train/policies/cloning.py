"""Behavior cloning consumes only verified training partition sequences."""
import torch
from ..dataset import DatasetPartition


def cloning_loss(policy,observations,actions,episode_starts,masks,valid):
    if not valid.any(): raise ValueError('Empty cloning sequence')
    outputs,_,_=policy.sequence(observations,episode_starts,valid=valid)
    if policy.nvec:
        loss=-policy.distribution(outputs,masks).log_prob(actions)
    else:
        predicted=outputs
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


class CloningSequenceCache:
    """Bounded tensor reuse with source bytes rechecked before every epoch."""
    def __init__(self,partition,policy,*,max_bytes=268435456):
        if type(max_bytes) is not int or not 1<=max_bytes<=268435456:raise ValueError('Cloning cache budget differs')
        self.partition=partition;self.policy=policy;self.max_bytes=max_bytes;self._sequences=None;self._disabled=False
    def _verify(self):
        import hashlib
        from pathlib import Path
        from ..dataset import DatasetManifest
        for path,manifest in self.partition.recordings:
            if DatasetManifest.load(path).hash!=manifest.hash:raise ValueError('Cached source manifest changed')
            for chunk in manifest.chunks:
                source=Path(path)/chunk.file
                if source.is_symlink() or source.stat().st_size!=chunk.bytes or hashlib.sha256(source.read_bytes()).hexdigest()!=chunk.sha256:raise ValueError('Cached source chunk changed')
    @staticmethod
    def _clone(sequence):
        observations,actions,starts,masks,valid=sequence
        return observations.clone(),actions.clone(),starts.clone(),None if masks is None else [m.clone() for m in masks],valid.clone()
    def sequences(self):
        self._verify()
        if self._sequences is not None:
            for sequence in self._sequences:yield self._clone(sequence)
            return
        entries=[];size=0
        for sequence in training_sequences(self.partition,self.policy):
            tensors=[sequence[0],sequence[1],sequence[2],sequence[4]]+([] if sequence[3] is None else sequence[3])
            size+=sum(t.numel()*t.element_size() for t in tensors)
            if not self._disabled and size<=self.max_bytes:entries.append(self._clone(sequence))
            else:entries.clear();self._disabled=True
            yield sequence
        if not self._disabled:self._sequences=tuple(entries)
