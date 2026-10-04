"""Append-only bounded recording. Incomplete bytes remain available for recovery."""
import hashlib
import json
import math
import os
from pathlib import Path
from .scenario import canonical_bytes, identifier, integer, ScenarioSpec, decode_json_bytes
from .dataset import ChunkReceipt, DatasetManifest, EpisodeReceipt, decode_chunk


def validate_record(row,metadata):
    required={'episode_id','tick','actor_generations','observations','proposed_actions','applied_actions',
              'fallback','delay_ticks','reward_terms','terminated','truncated'}
    optional={'observation_schema_hash','action_schema_hash','game_build_hash','model_hash','legality','execution_legality','teacher_labels','physical_diagnostics'}
    if not isinstance(row,dict) or not required<=set(row) or set(row)-required-optional:
        raise ValueError('Invalid demonstration record')
    for pin in optional-{'legality','execution_legality','teacher_labels','physical_diagnostics'}:
        if pin in row and row[pin]!=metadata[pin]: raise ValueError('Recording schema/model pin changed')
    physical=metadata.get('recording_settings',{}).get('physical_diagnostics')
    if physical is not None or 'physical_diagnostics' in row:
        from .multi_physical_diagnostics import PHYSICAL_CONTRACT,validate_physical_pair
        if physical!=PHYSICAL_CONTRACT or 'physical_diagnostics' not in row:raise ValueError('Physical diagnostics admission metadata differs')
        validate_physical_pair(row['physical_diagnostics'],row)
    identifier(row['episode_id']); integer(row['tick'],0,2**53-1)
    actors=row['actor_generations']
    if not isinstance(actors,dict) or not 1<=len(actors)<=256: raise ValueError('Invalid recording actors')
    for actor,generation in actors.items(): identifier(actor); integer(generation,1,2**53-1)
    for key in ('observations','proposed_actions','applied_actions','fallback','delay_ticks'):
        if not isinstance(row[key],dict) or set(row[key])!=set(actors): raise ValueError('Actor record identity differs')
    for key in ('observations','proposed_actions','applied_actions'):
        for values in row[key].values():
            if not isinstance(values,list) or not 1<=len(values)<=(65536 if key=='observations' else 4096) or any(type(v) not in (int,float) or not math.isfinite(v) for v in values):
                raise ValueError('Invalid observation/action values')
    for key in ('legality','execution_legality'):
        if key not in row: continue
        masks=row[key]
        if not isinstance(masks,dict) or set(masks)!=set(actors): raise ValueError('Legality actor identity differs')
        for mask in masks.values():
            if not isinstance(mask,list) or len(mask)>128 or any(not isinstance(b,list) or not 1<=len(b)<=256 or not any(b) or any(type(v) is not bool for v in b) for b in mask):
                raise ValueError('Invalid recorded legality mask')
    labels=row.get('teacher_labels');dagger=metadata.get('recording_settings',{}).get('label_mode')=='dagger-v1'
    if dagger or labels is not None:
        if not dagger or metadata['partition']!='train' or metadata['source']!='policy' or metadata.get('recording_settings',{}).get('label_source')!='privileged-training-only-route':raise ValueError('Corrective teacher labels require explicit TRAIN policy recording')
        if not isinstance(labels,dict) or set(labels)!=set(actors) or 'legality' not in row:raise ValueError('Teacher label actor/legality identity differs')
        for actor,values in labels.items():
            masks=row['legality'][actor]
            if not isinstance(values,list) or len(values)!=len(masks) or any(type(v) not in (int,float) or not math.isfinite(v) or v!=int(v) or not 0<=v<len(mask) or not mask[int(v)] for v,mask in zip(values,masks)):raise ValueError('Teacher label violates fresh action legality')
    if any(type(v) is not bool for v in row['fallback'].values()): raise ValueError('Invalid fallback flags')
    for delay in row['delay_ticks'].values(): integer(delay,0,1000)
    if type(row['terminated']) is not bool or type(row['truncated']) is not bool or (row['terminated'] and row['truncated']):
        raise ValueError('Invalid episode outcome')
    terms={t['id']:t['cap'] for t in metadata['scenario']['reward_terms']}
    if not isinstance(row['reward_terms'],dict) or set(row['reward_terms'])!=set(terms): raise ValueError('Reward term identity differs')
    for key,value in row['reward_terms'].items():
        if type(value) not in (int,float) or not math.isfinite(value) or abs(value)>terms[key]: raise ValueError('Reward cap exceeded')
    canonical_bytes(row)


class DemonstrationRecorder:
    def __init__(self,path,*,scenario:ScenarioSpec,session_id,run_id,environment_id,source,model_hash,
                 chunk_records=256,chunk_bytes=8_388_608,recording_settings=None,compression=None):
        if compression not in (None,'gzip'):raise ValueError('Unsupported chunk compression')
        self._compression=compression;self._raw=None
        settings=dict(recording_settings or {})
        if 'chunk_encoding' in settings:raise ValueError('Chunk encoding is owned by recorder')
        if compression:settings['chunk_encoding']='gzip-jsonl-v1'
        self.path=Path(path); self.path.mkdir(parents=True,exist_ok=True)
        self.chunk_records=integer(chunk_records,1,1024); self.chunk_bytes=integer(chunk_bytes,1_048_577,8_388_608)
        if source not in ('player','scripted','policy'): raise ValueError('Invalid recording source')
        self._meta={'schema_version':1,'session_id':identifier(session_id),'run_id':identifier(run_id),
            'environment_id':identifier(environment_id),'source':source,'model_hash':identifier(model_hash),
            'scenario':scenario.to_dict(),'scenario_hash':scenario.hash,'partition':scenario.partition,
            'observation_schema_hash':scenario.observation_schema_hash,'action_schema_hash':scenario.action_schema_hash,
            'game_build_hash':scenario.game_build_hash,'recording_settings':settings}
        data=canonical_bytes(self.meta,max_bytes=65536)
        with (self.path/'recording.json').open('xb') as stream: stream.write(data)
        self._stream=None; self._count=0; self._bytes=0; self._hash=None
        self.chunks=[]; self.episodes=[]; self._episode=None; self._steps=0; self._last_tick=-1
        self._ended=True; self._closed=False; self._faulted=False; self._widths={}; self._physical=None
    @property
    def meta(self): return json.loads(canonical_bytes(self._meta,max_bytes=65536))
    def append(self,row):
        if self._closed or self._faulted: raise ValueError('Recording is closed or faulted')
        validate_record(row,self.meta)
        row=json.loads(canonical_bytes(row))
        from .multi_physical_diagnostics import validate_physical_continuity
        physical=validate_physical_continuity(self._physical,row)
        episode=row['episode_id']
        if episode!=self._episode:
            if not self._ended or any(e.episode_id==episode for e in self.episodes): raise ValueError('Episode boundary is missing or reused')
        elif self._ended or row['tick']<=self._last_tick: raise ValueError('Episode ended or tick did not advance')
        widths={k:len(next(iter(row[k].values()))) for k in ('observations','proposed_actions','applied_actions')}
        if any(any(len(v)!=widths[k] for v in row[k].values()) for k in widths) or (self._widths and widths!=self._widths):
            raise ValueError('Sensor/action width changed')
        encoded=canonical_bytes(row)+b'\n'
        if self._stream and (self._count>=self.chunk_records or self._bytes+len(encoded)>self.chunk_bytes): self._seal()
        if self._stream is None:
            suffix='.gz' if self._compression else ''
            self._file=f'chunk-{len(self.chunks):06d}.jsonl{suffix}'
            self._raw=(self.path/self._file).open('xb')
            if self._compression:
                import gzip
                self._stream=gzip.GzipFile(filename='',mode='wb',fileobj=self._raw,mtime=0)
            else:self._stream=self._raw
            self._hash=hashlib.sha256(); self._count=0; self._bytes=0
        try:
            self._stream.write(encoded); self._stream.flush()
        except BaseException:
            self._faulted=True; raise
        self._hash.update(encoded)
        self._count+=1; self._bytes+=len(encoded); self._widths=widths
        if episode!=self._episode:
            self._episode=episode; self._steps=0
        self._physical=physical
        self._steps+=1; self._last_tick=row['tick']; self._ended=row['terminated'] or row['truncated']
        if self._ended:
            self.episodes.append(EpisodeReceipt(episode,self.meta['scenario_hash'],self.meta['session_id'],self._steps,
                self.meta['observation_schema_hash'],self.meta['action_schema_hash'],self.meta['game_build_hash'],
                self.meta['partition'],self.meta['source']))
    def _seal(self):
        if self._stream is None: return
        self._stream.flush();os.fsync(self._stream.fileno());self._stream.close();self._stream=None
        if self._raw is not None and not self._raw.closed:
            self._raw.flush();os.fsync(self._raw.fileno());self._raw.close()
        data=(self.path/self._file).read_bytes()
        if len(data)>self.chunk_bytes:raise ValueError('Compressed chunk storage exceeds byte budget')
        self.chunks.append(ChunkReceipt(self._file,hashlib.sha256(data).hexdigest(),self._count,len(data)))
    def finalize(self):
        if self._closed or self._faulted or not self.episodes or not self._ended: raise ValueError('Recording has no completed episodes')
        self._seal()
        m=DatasetManifest(self.meta['partition'],self.meta['observation_schema_hash'],self.meta['action_schema_hash'],
            self.meta['game_build_hash'],self.meta['session_id'],self.meta['scenario_hash'],tuple(self.chunks),tuple(self.episodes),self.meta)
        encoded=canonical_bytes(m.to_dict(),max_bytes=16_777_216)
        temp=self.path/'manifest.tmp'
        with temp.open('xb') as stream: stream.write(encoded); stream.flush(); os.fsync(stream.fileno())
        os.replace(temp,self.path/'manifest.json'); self._closed=True
        return m
    def abort(self):
        if self._stream: self._stream.close(); self._stream=None
        if self._raw and not self._raw.closed:self._raw.close()
        self._closed=True


def recover_recording(path):
    path=Path(path)
    metadata=decode_json_bytes((path/'recording.json').read_bytes(),65536); ScenarioSpec.from_dict(metadata['scenario'])
    if (path/'manifest.json').exists():
        manifest=DatasetManifest.load(path); list(manifest.records(path))
        return {'status':'complete','manifest_hash':manifest.hash}
    chunks=[]
    compressed=metadata.get('recording_settings',{}).get('chunk_encoding')=='gzip-jsonl-v1'
    suffix='.gz' if compressed else ''
    files=sorted(path.glob('chunk-*.jsonl'+suffix))
    for i,file in enumerate(files):
        if file.name!=f'chunk-{i:06d}.jsonl{suffix}' or file.stat().st_size>8_388_608: raise ValueError('Invalid recovery chunks')
        data=file.read_bytes(); valid=0
        decoded=decode_chunk(data,compressed=compressed,allow_partial=True)
        for line in decoded.splitlines(keepends=True):
            if not line.endswith(b'\n'): break
            try: validate_record(decode_json_bytes(line),metadata)
            except (ValueError,TypeError): break
            valid+=1
        chunks.append({'file':file.name,'sha256':hashlib.sha256(data).hexdigest(),
                       'valid_records':valid,'complete':i<len(files)-1})
    return {'status':'interrupted','chunks':chunks,'session_id':metadata['session_id']}


def record_episode(env,recorder,action_source,*,seed=None,on_step=None,label_source=None):
    """Capture observed input before applying the action through the shared host."""
    expected=recorder.meta
    actual_seed=expected['scenario']['seed'] if seed is None else seed
    if actual_seed!=expected['scenario']['seed']: raise ValueError('Recording seed differs')
    observation,info=env.reset(seed=actual_seed)
    for pin,key in (('game_build_hash','build_id'),('observation_schema_hash','observation_schema_hash'),('action_schema_hash','action_schema_hash')):
        if expected[pin]!=info[key]: raise ValueError('Environment differs from recording pins')
    steps=0
    while True:
        labels=None if label_source is None else label_source(observation.copy(),dict(info))
        proposed=action_source(observation.copy(),dict(info))
        next_observation,reward,terminated,truncated,next_info=env.step(proposed)
        if next_info.get('worker_failed'): recorder.abort(); raise RuntimeError('Worker failed while recording')
        actor=env.actor_id
        applied=next_info.get('accepted_action')
        if not isinstance(applied,(list,tuple)): raise ValueError('Applied controller action receipt is missing')
        row={'episode_id':info['episode_id'],'tick':next_info['tick'],
             'actor_generations':info['actor_generations'],'observations':{actor:observation.tolist()},
             'proposed_actions':{actor:list(map(float,proposed))},'applied_actions':{actor:list(map(float,applied))},
             'fallback':{actor:bool(next_info.get('fallback',False))},
             'delay_ticks':{actor:next_info.get('delay_ticks',0)},
             'reward_terms':next_info['reward_terms'],'terminated':terminated,'truncated':truncated}
        if 'legality' in info: row['legality']={actor:info['legality']}
        if 'execution_legality' in next_info: row['execution_legality']={actor:next_info['execution_legality']}
        if labels is not None:row['teacher_labels']={actor:list(map(float,labels))}
        recorder.append(row); steps+=1
        if on_step is not None:on_step(dict(next_info))
        observation,info=next_observation,next_info
        if terminated or truncated: return steps


def replay_recording(worker,path,*,atol=1e-6):
    """Replay proposed actions and compare observed input and applied receipts."""
    import numpy as np
    from .gym_env import ZyrenEnv
    manifest=DatasetManifest.load(path); rows=list(manifest.records(path))
    first=rows[0]; actor=next(iter(first['observations']))
    scenario=manifest.recording['scenario']
    env=ZyrenEnv(worker,environment_id='replay',scenario=scenario['id'],actor_id=actor,
        purpose={'train':'training','validation':'validation','test':'test'}[manifest.partition],
        observation_width=len(first['observations'][actor]),action_width=len(first['proposed_actions'][actor]))
    count=0; episode=None
    try:
        for row in rows:
            if row['episode_id']!=episode:
                observation,info=env.reset(seed=scenario['seed']); episode=row['episode_id']
                for pin,key in (('game_build_hash','build_id'),('observation_schema_hash','observation_schema_hash'),('action_schema_hash','action_schema_hash')):
                    if getattr(manifest,pin)!=info[key]: raise ValueError('Replay schema/build pin differs')
            if not np.allclose(observation,row['observations'][actor],atol=atol,rtol=0): raise ValueError('Replay observed input differs')
            proposed=row['proposed_actions'][actor]
            if isinstance(env.action_space,__import__('gymnasium').spaces.MultiDiscrete):
                if any(v!=int(v) for v in proposed): raise ValueError('Discrete replay action differs')
                proposed=np.asarray(proposed,dtype=np.int64)
            previous_info=info
            observation,reward,terminated,truncated,info=env.step(proposed)
            if info.get('worker_failed') or info['tick']!=row['tick'] or not np.allclose(info['accepted_action'],row['applied_actions'][actor],atol=atol,rtol=0):
                raise ValueError('Replay controller receipt differs')
            if terminated!=row['terminated'] or truncated!=row['truncated'] or bool(info.get('fallback',False))!=row['fallback'][actor]:
                raise ValueError('Replay outcome/fallback differs')
            if 'legality' in row and row['legality'][actor]!=previous_info.get('legality'): raise ValueError('Replay captured legality differs')
            if 'execution_legality' in row and row['execution_legality'][actor]!=info.get('execution_legality'): raise ValueError('Replay execution legality differs')
            if info.get('delay_ticks',0)!=row['delay_ticks'][actor] or set(info['reward_terms'])!=set(row['reward_terms']) or any(abs(info['reward_terms'][k]-v)>atol for k,v in row['reward_terms'].items()):
                raise ValueError('Replay reward/delay differs')
            count+=1
        return {'steps':count,'manifest_hash':manifest.hash,'game_build_hash':manifest.game_build_hash,
                'observation_schema_hash':manifest.observation_schema_hash,'action_schema_hash':manifest.action_schema_hash,'matched':True}
    finally: env.close()
