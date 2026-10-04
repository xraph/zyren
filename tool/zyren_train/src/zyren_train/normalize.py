"""Training-only observation statistics, pinned to their source episodes."""
from dataclasses import dataclass
import hashlib
import math
from .scenario import canonical_bytes


@dataclass(frozen=True)
class ObservationSample:
    session_id: str
    episode_id: str
    scenario_hash: str
    values: tuple[float,...]


@dataclass(frozen=True)
class ObservationNormalizer:
    mean: tuple[float,...]
    scale: tuple[float,...]
    count: int
    observation_schema_hash: str
    source_hash: str
    source_partition: str = 'train'
    @classmethod
    def fit(cls,train_partition,*,observations=None):
        if train_partition.name!='train' or not train_partition.episodes: raise ValueError('Fit requires nonempty training partition')
        pins={e.observation_schema_hash for e in train_partition.episodes}
        if len(pins)!=1: raise ValueError('Observation profiles differ')
        allowed={(e.session_id,e.episode_id,e.scenario_hash) for e in train_partition.episodes}
        mean=[]; m2=[]; count=0
        content=hashlib.sha256()
        for sample in train_partition.observation_samples() if observations is None else observations:
            if not isinstance(sample,ObservationSample) or (sample.session_id,sample.episode_id,sample.scenario_hash) not in allowed:
                raise ValueError('Observation belongs to another source episode')
            content.update(canonical_bytes(sample.__dict__)); content.update(b"\n")
            values=list(sample.values)
            if not values or len(values)>65536 or (count and len(values)!=len(mean)) or any(type(v) not in (int,float) or not math.isfinite(v) for v in values):
                raise ValueError('Invalid observation width/values')
            if count==0: mean=[0.]*len(values); m2=[0.]*len(values)
            count+=1
            if count>10_000_000: raise ValueError('Normalization sample budget exceeded')
            for i,value in enumerate(values):
                delta=value-mean[i]; mean[i]+=delta/count; m2[i]+=delta*(value-mean[i])
                if not math.isfinite(mean[i]) or not math.isfinite(m2[i]): raise ValueError('Observation statistics overflow')
        if not count: raise ValueError('No observations to fit')
        lineage={'episodes':[e.__dict__ for e in train_partition.episodes],
                 'manifests':sorted(manifest.hash for _,manifest in train_partition.recordings),
                 'samples_sha256':content.hexdigest(),
                 'mode':'verified-recordings' if observations is None else 'explicit-samples'}
        source=hashlib.sha256(canonical_bytes(lineage,16_777_216)).hexdigest()
        return cls(tuple(mean),tuple(max(math.sqrt(max(0,v/count)),1e-6) for v in m2),count,next(iter(pins)),source)
    def transform(self,row):
        if len(row)!=len(self.mean) or any(not math.isfinite(v) for v in row): raise ValueError('Invalid observation')
        return [(v-m)/s for v,m,s in zip(row,self.mean,self.scale)]
