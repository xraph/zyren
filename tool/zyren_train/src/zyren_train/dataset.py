"""Finalized, hash-verified demonstration manifests and partition membership."""
from dataclasses import dataclass, asdict
import hashlib
import json
from pathlib import Path
from .scenario import PARTITIONS, canonical_bytes, identifier, integer, decode_json_bytes


def decode_chunk(data,*,compressed=False,allow_partial=False):
    if len(data)>8_388_608:raise ValueError('Chunk byte budget exceeded')
    if not compressed:return data
    import zlib
    try:
        decoder=zlib.decompressobj(31);value=decoder.decompress(data,8_388_609)
    except zlib.error as error:raise ValueError('Invalid compressed chunk') from error
    if len(value)>8_388_608 or decoder.unconsumed_tail:raise ValueError('Decompressed chunk budget exceeded')
    if decoder.unused_data:raise ValueError('Unexpected compressed chunk member or trailing bytes')
    if not decoder.eof and not allow_partial:raise ValueError('Compressed chunk trailer is missing')
    return value


class _FrozenDict(dict):
    def _immutable(self,*args,**kwargs): raise TypeError('Dataset metadata is immutable')
    __setitem__=__delitem__=clear=pop=popitem=setdefault=update=_immutable
    __ior__=_immutable


def _freeze(value):
    if isinstance(value,dict): return _FrozenDict((k,_freeze(v)) for k,v in value.items())
    if isinstance(value,list): return tuple(_freeze(v) for v in value)
    return value


@dataclass(frozen=True)
class EpisodeReceipt:
    episode_id: str
    scenario_hash: str
    session_id: str
    steps: int
    observation_schema_hash: str
    action_schema_hash: str
    game_build_hash: str
    partition: str | None
    source: str
    def __post_init__(self):
        for key in ('episode_id','scenario_hash','session_id','observation_schema_hash','action_schema_hash','game_build_hash'):
            identifier(getattr(self,key))
        integer(self.steps,1)
        if self.partition is not None and self.partition not in PARTITIONS: raise ValueError('Invalid partition')
        if self.source not in ('player','scripted','policy'): raise ValueError('Invalid demonstration source')


@dataclass(frozen=True)
class ChunkReceipt:
    file: str
    sha256: str
    records: int
    bytes: int
    def __post_init__(self):
        import re
        if not re.fullmatch(r'chunk-[0-9]{6}\.jsonl(?:\.gz)?',self.file): raise ValueError('Invalid chunk path')
        if not re.fullmatch(r'[0-9a-f]{64}',self.sha256): raise ValueError('Invalid chunk hash')
        integer(self.records,1,1024); integer(self.bytes,1,8_388_608)


@dataclass(frozen=True)
class DatasetPartition:
    name: str
    episodes: tuple[EpisodeReceipt,...]
    recordings: tuple[tuple[str,object],...] = ()
    def __post_init__(self):
        if self.name not in PARTITIONS: raise ValueError('Invalid partition')
        if len(self.episodes)>100_000: raise ValueError('Episode budget exceeded')
        if any(e.partition not in (None,self.name) for e in self.episodes):
            raise ValueError('Source episode belongs to another partition')
    @classmethod
    def from_recordings(cls,name,paths):
        paths=tuple(paths)
        if not paths or len(paths)>100_000: raise ValueError('Missing or oversized recording collection')
        recordings=tuple((str(path),DatasetManifest.load(path)) for path in paths)
        episodes=tuple(e for _,manifest in recordings for e in manifest.episodes)
        return cls(name,episodes,recordings)
    def observation_samples(self):
        if not self.recordings: raise ValueError('Partition has no source recordings')
        expected={(e.session_id,e.episode_id,e.scenario_hash) for e in self.episodes}
        seen=set()
        for path,manifest in self.recordings:
            if manifest.partition!=self.name: raise ValueError('Recording source partition differs')
            receipts={(e.session_id,e.episode_id,e.scenario_hash) for e in manifest.episodes}
            if not receipts<=expected or receipts&seen: raise ValueError('Recording episode membership differs')
            seen.update(receipts)
            yield from manifest.observation_samples(path)
        if seen!=expected: raise ValueError('Partition source coverage differs')
    @property
    def scenario_hashes(self): return frozenset(e.scenario_hash for e in self.episodes)
    @property
    def session_ids(self): return frozenset(e.session_id for e in self.episodes)


@dataclass(frozen=True)
class DatasetManifest:
    partition: str
    observation_schema_hash: str
    action_schema_hash: str
    game_build_hash: str
    session_id: str
    scenario_hash: str
    chunks: tuple[ChunkReceipt,...]
    episodes: tuple[EpisodeReceipt,...]
    recording: dict
    schema_version: int = 1
    def __post_init__(self):
        if type(self.schema_version) is not int or self.schema_version!=1 or self.partition not in PARTITIONS: raise ValueError('Unsupported dataset schema')
        for key in ('observation_schema_hash','action_schema_hash','game_build_hash','session_id','scenario_hash'):
            identifier(getattr(self,key))
        if not self.episodes or len(self.episodes)>100_000 or not self.chunks or len(self.chunks)>100_000:
            raise ValueError('Empty or oversized dataset')
        if len({e.episode_id for e in self.episodes})!=len(self.episodes): raise ValueError('Duplicate episode')
        encoding=self.recording.get('recording_settings',{}).get('chunk_encoding','jsonl-v1')
        if encoding not in ('jsonl-v1','gzip-jsonl-v1'):raise ValueError('Unknown chunk encoding')
        suffix='.gz' if encoding=='gzip-jsonl-v1' else ''
        if tuple(c.file for c in self.chunks)!=tuple(f'chunk-{i:06d}.jsonl{suffix}' for i in range(len(self.chunks))):
            raise ValueError('Chunk sequence differs')
        for e in self.episodes:
            if (e.partition,e.session_id,e.scenario_hash,e.observation_schema_hash,e.action_schema_hash,e.game_build_hash)!=(
                self.partition,self.session_id,self.scenario_hash,self.observation_schema_hash,self.action_schema_hash,self.game_build_hash):
                raise ValueError('Episode identity differs')
        if sum(c.records for c in self.chunks)!=sum(e.steps for e in self.episodes):
            raise ValueError('Episode and chunk counts differ')
        canonical_bytes(self.recording,max_bytes=65536)
        for key in ('partition','session_id','scenario_hash','observation_schema_hash','action_schema_hash','game_build_hash'):
            if self.recording.get(key)!=getattr(self,key): raise ValueError('Recording manifest pins differ')
        from .scenario import ScenarioSpec
        scenario=ScenarioSpec.from_dict(json.loads(canonical_bytes(self.recording['scenario'])))
        if scenario.hash!=self.scenario_hash or scenario.partition!=self.partition: raise ValueError('Scenario identity differs')
        object.__setattr__(self,'recording',_freeze(self.recording))
    def to_dict(self): return asdict(self)
    @property
    def hash(self): return hashlib.sha256(canonical_bytes(self.to_dict(),max_bytes=16_777_216)).hexdigest()
    @classmethod
    def load(cls,path):
        p=Path(path)/'manifest.json'
        if not p.exists() or p.stat().st_size>16_777_216: raise ValueError('Finalized bounded manifest is missing')
        data=decode_json_bytes(p.read_bytes(),max_bytes=16_777_216)
        try:
            data['chunks']=tuple(ChunkReceipt(**v) for v in data['chunks'])
            data['episodes']=tuple(EpisodeReceipt(**v) for v in data['episodes'])
            return cls(**data)
        except (TypeError,KeyError) as e: raise ValueError('Invalid dataset manifest') from e
    def records(self,path):
        from .demonstration import validate_record
        counts={}; ticks={}; ended=set(); widths={}
        for chunk in self.chunks:
            p=Path(path)/chunk.file
            if p.stat().st_size!=chunk.bytes: raise ValueError('Chunk hash/size differs')
            data=p.read_bytes()
            if hashlib.sha256(data).hexdigest()!=chunk.sha256: raise ValueError('Chunk hash differs')
            data=decode_chunk(data,compressed=chunk.file.endswith('.gz'))
            lines=data.splitlines()
            if len(lines)!=chunk.records: raise ValueError('Chunk record count differs')
            for line in lines:
                record=decode_json_bytes(line); validate_record(record,self.recording)
                ep=record['episode_id']
                if ep in ended or record['tick']<=ticks.get(ep,-1): raise ValueError('Episode order differs')
                if ep not in counts and counts and not set(counts)<=ended: raise ValueError('Episode boundary is missing')
                ticks[ep]=record['tick']
                if record['terminated'] or record['truncated']: ended.add(ep)
                for key in ('observations','proposed_actions','applied_actions'):
                    size={len(v) for v in record[key].values()}
                    if len(size)!=1 or (key in widths and widths[key] not in size): raise ValueError('Recording width differs')
                    widths[key]=next(iter(size))
                counts[ep]=counts.get(ep,0)+1
                yield record
        if ended!=set(counts) or counts!={e.episode_id:e.steps for e in self.episodes}: raise ValueError('Episode record counts differ')

    def observation_samples(self,path):
        from .normalize import ObservationSample
        for record in self.records(path):
            for values in record['observations'].values():
                yield ObservationSample(self.session_id,record['episode_id'],self.scenario_hash,tuple(values))
