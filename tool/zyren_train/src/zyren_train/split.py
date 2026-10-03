"""Scenario/session groups are assigned before fitting any statistics."""
import hashlib
from .dataset import DatasetPartition


def validate_partitions(partitions):
    scenarios=set(); sessions=set(); episodes=set()
    for name,p in partitions.items():
        if name!=p.name: raise ValueError('Partition name differs')
        if scenarios&p.scenario_hashes or sessions&p.session_ids: raise ValueError('Scenario/session leakage across partitions')
        ids={(e.session_id,e.episode_id) for e in p.episodes}
        if len(ids)!=len(p.episodes) or ids&episodes: raise ValueError('Duplicate episode')
        scenarios.update(p.scenario_hashes); sessions.update(p.session_ids); episodes.update(ids)


def split_by_scenario(episodes,*,seed=7,train_fraction=.7,validation_fraction=.15):
    episodes=tuple(episodes)
    if not episodes or len(episodes)>100_000: raise ValueError('Empty or oversized dataset')
    if type(seed) is not int or not 0<=seed<=2**53-1 or not 0<train_fraction<1 or not 0<=validation_fraction<1-train_fraction:
        raise ValueError('Invalid split settings')
    parents=list(range(len(episodes)))
    def find(i):
        while parents[i]!=i: parents[i]=parents[parents[i]]; i=parents[i]
        return i
    seen={}
    for i,e in enumerate(episodes):
        for key in (('scenario',e.scenario_hash),('session',e.session_id)):
            if key in seen: parents[find(i)]=find(seen[key])
            else: seen[key]=i
    groups={}
    for i,e in enumerate(episodes): groups.setdefault(find(i),[]).append(e)
    output={k:[] for k in ('train','validation','test')}
    for group in groups.values():
        pins={e.partition for e in group if e.partition is not None}
        if len(pins)>1: raise ValueError('Pinned scenario/session crosses source partitions')
        identity='|'.join(sorted({e.scenario_hash for e in group}|{e.session_id for e in group}))
        value=int.from_bytes(hashlib.sha256(f'{seed}:{identity}'.encode()).digest()[:8],'big')/2**64
        name=next(iter(pins)) if pins else ('train' if value<train_fraction else 'validation' if value<train_fraction+validation_fraction else 'test')
        output[name].extend(group)
    result={name:DatasetPartition(name,tuple(sorted(rows,key=lambda e:(e.session_id,e.episode_id)))) for name,rows in output.items()}
    validate_partitions(result)
    return result
