"""Native TRAIN-only teacher labels recorded with the existing dataset contract."""
from pathlib import Path
import hashlib
import time
import numpy as np
from .demonstration import DemonstrationRecorder,record_episode
from .gym_env import ZyrenEnv
from .scenario import ScenarioSpec,canonical_bytes


def record_teacher(worker,*,scenario,seed,output,session_id,disk_mib=512):
    if type(seed) is not int or not 0<=seed<2**31 or type(disk_mib) is not int or not 128<=disk_mib<=4096:raise ValueError('Teacher recording budget differs')
    output=Path(output)
    if output.exists():raise ValueError('Teacher recording identity already exists')
    env=ZyrenEnv(worker,scenario=scenario,purpose='training',observation_width=None,environment_id=session_id)
    recorder=None;start=time.monotonic();collisions=False;final=None
    try:
        _,info=env.reset(seed=seed);spec=ScenarioSpec.from_dict(info['scenario_spec'])
        if spec.partition!='train' or spec.seed!=seed or not spec.settings.get('visual') or info.get('visual_source')!='actual-native-readback':raise ValueError('Native visual TRAIN scenario required')
        schema=info['observation_schema'];profile=info['visual_profile']
        if [f['name'] for f in schema['fields']]!=['camera','own-body'] or not {'teacher_action','teacher_observation'}<=set(info.get('training_only_fields',[])):raise ValueError('Teacher input separation differs')
        recorder=DemonstrationRecorder(output,scenario=spec,session_id=session_id,run_id=worker.run_id,environment_id=env.environment_id,source='scripted',model_hash='native-teacher-v1',compression='gzip',recording_settings={'input_source':info['teacher_source'],'student_fields':['camera','own-body'],'visual_profile':profile,'teacher_observations_recorded':False})
        def action_source(observation,current):
            if len(observation)!=sum(f['width'] for f in schema['fields']) or current['observation_schema_hash']!=spec.observation_schema_hash or current['action_schema_hash']!=spec.action_schema_hash:raise ValueError('Teacher student profile changed')
            return np.asarray(current['teacher_action'],dtype=np.int64 if current['action_space']['kind']=='multi_discrete' else np.float32)
        def capture(current):
            nonlocal final,collisions
            final=current;collisions|=bool(current['collision'])
            if sum(p.stat().st_size for p in output.iterdir() if p.is_file())>disk_mib*1048576:raise ValueError('Teacher recording disk budget exceeded')
        steps=record_episode(env,recorder,action_source,seed=seed,on_step=capture)
        manifest=recorder.finalize()
        result={'schema_version':1,'scenario_hash':spec.hash,'recording_manifest_hash':manifest.hash,'partition':'train','seed':seed,'steps':steps,'success':bool(final['success']),'collision':collisions,'visual_source':'actual-native-readback','duration_seconds':time.monotonic()-start,'student_fields':['camera','own-body'],'teacher_observations_recorded':False,'observation_schema_hash':spec.observation_schema_hash,'action_schema_hash':spec.action_schema_hash}
        result['sha256']=hashlib.sha256(canonical_bytes(result)).hexdigest()
        return result
    except BaseException:
        if recorder is not None:recorder.abort()
        raise
    finally:env.close()
