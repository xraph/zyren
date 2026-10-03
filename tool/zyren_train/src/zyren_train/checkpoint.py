"""Atomic model/optimizer/RNG checkpoints, verified before any restore mutation."""
from dataclasses import dataclass
import hashlib
import os
import random
import numpy as np
import torch
from .scenario import canonical_bytes, decode_json_bytes


@dataclass(frozen=True)
class TrainingCheckpoint:
    path: object
    sha256: str
    steps: int
    @staticmethod
    def save(run,*,policy,optimizer,steps,updates,curriculum,normalization,config_hash,source_pins,cloning_progress):
        rng=np.random.get_state()
        state={'version':1,'config_hash':config_hash,'steps':steps,'updates':updates,
               'policy_distribution':policy.distribution_id,'model':policy.state_dict(),'optimizer':optimizer.state_dict(),
               'torch_rng':torch.get_rng_state(),'python_rng':random.getstate(),
               'numpy_rng':(rng[0],rng[1].tolist(),rng[2],rng[3],rng[4]),
               'curriculum':curriculum,'normalization':normalization,'source_pins':source_pins,'cloning_progress':dict(cloning_progress),
               'environment_restore':'reset-boundary','numerical_reproducibility':False}
        name=f'checkpoint-{steps:012d}-{updates:08d}-{run.sequence:06d}.pt'; path=run.path/name; temporary=run.path/(name+'.tmp')
        if path.exists() or temporary.exists(): raise ValueError('Checkpoint identity already exists')
        with temporary.open('xb') as stream:
            torch.save(state,stream); stream.flush(); os.fsync(stream.fileno())
        if temporary.stat().st_size>100_663_296: temporary.unlink(); raise ValueError('Checkpoint byte budget exceeded')
        digest=hashlib.sha256(temporary.read_bytes()).hexdigest(); os.replace(temporary,path)
        receipt={'version':1,'file':name,'sha256':digest,'steps':steps,'updates':updates,'config_hash':config_hash,
                 'environment_restore':'reset-boundary','numerical_reproducibility':False}
        pointer=run.path/'checkpoint.json.tmp'
        with pointer.open('wb') as stream:
            stream.write(canonical_bytes(receipt)); stream.flush(); os.fsync(stream.fileno())
        os.replace(pointer,run.path/'checkpoint.json')
        return TrainingCheckpoint(path,digest,steps)
    @staticmethod
    def load(run,config_hash):
        import re
        data=decode_json_bytes((run.path/'checkpoint.json').read_bytes(),65536)
        if data.get('version')!=1 or data.get('config_hash')!=config_hash or not re.fullmatch(r'checkpoint-[0-9]{12}-[0-9]{8}(?:-[0-9]{6})?\.pt',data.get('file','')): raise ValueError('Checkpoint config or identity differs')
        path=run.path/data['file']
        if not path.is_file() or path.stat().st_size>100_663_296 or hashlib.sha256(path.read_bytes()).hexdigest()!=data['sha256']: raise ValueError('Checkpoint hash differs')
        state=torch.load(path,map_location='cpu',weights_only=True)
        if state['version']!=1 or state['config_hash']!=config_hash or state['steps']!=data['steps'] or state['updates']!=data['updates'] or state['environment_restore']!='reset-boundary': raise ValueError('Checkpoint pins differ')
        if state.get('policy_distribution') not in ('masked-categorical-v1','censored-normal-v1'): raise ValueError('Checkpoint policy distribution is missing or incompatible')
        if any(not torch.isfinite(value).all() for value in state['model'].values()): raise ValueError('Nonfinite checkpoint weights')
        state['_checkpoint_file']=data['file']; state['_checkpoint_sha256']=data['sha256']
        return state
    @staticmethod
    def restore_rng(state):
        torch.set_rng_state(state['torch_rng']); random.setstate(state['python_rng'])
        value=state['numpy_rng']; np.random.set_state((value[0],np.asarray(value[1],dtype=np.uint32),value[2],value[3],value[4]))
