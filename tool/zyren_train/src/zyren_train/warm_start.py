"""Pinned actor initialization with fresh optimizer and TRAIN normalization."""
from pathlib import Path
import hashlib,io,re
import torch


def validate_initial_actor(value):
    keys={'config','config_sha256','checkpoint','checkpoint_sha256'}
    if not isinstance(value,dict) or set(value)!=keys:raise ValueError('Initial actor pins are incomplete')
    if any(not isinstance(value[k],str) or not value[k] or len(value[k])>4096 for k in ['config','checkpoint']):raise ValueError('Initial actor path differs')
    if any(not isinstance(value[k],str) or not re.fullmatch('[0-9a-f]{64}',value[k]) for k in ['config_sha256','checkpoint_sha256']):raise ValueError('Initial actor digest differs')


def _read_pin(path,digest,budget):
    source=Path(path)
    if source.is_symlink() or not source.is_file() or not 1<=source.stat().st_size<=budget:raise ValueError('Initial actor file boundary differs')
    value=source.read_bytes()
    if len(value)>budget or len(value)!=source.stat().st_size or hashlib.sha256(value).hexdigest()!=digest:raise ValueError('Initial actor file hash differs')
    return value


def actor_state_for_normalization(policy,source_model):
    """Stage actor tensors without mutating either policy or source state."""
    target=policy.state_dict()
    if not isinstance(source_model,dict) or set(source_model)!=set(target):raise ValueError('Initial actor tensor names differ')
    for key,value in source_model.items():
        if not isinstance(value,torch.Tensor) or value.device.type!='cpu' or value.dtype!=target[key].dtype or value.shape!=target[key].shape or not torch.isfinite(value).all():raise ValueError('Initial actor tensor shape or value differs')
    old_mean=source_model['observation_mean'];old_scale=source_model['observation_scale']
    new_mean=target['observation_mean'];new_scale=target['observation_scale']
    if not (old_scale>0).all() or not (new_scale>0).all() or not torch.isfinite(new_mean).all() or not torch.isfinite(new_scale).all():raise ValueError('Initial actor normalization differs')
    result={k:v.detach().clone() for k,v in target.items()}
    for key,value in source_model.items():
        if key not in ['observation_mean','observation_scale'] and not key.startswith('value_head.'):result[key]=value.detach().clone()
    if hasattr(policy,'channels'):
        prefix=policy.channels*84*84
        if not torch.equal(old_mean[:prefix],torch.zeros_like(old_mean[:prefix])) or not torch.equal(new_mean[:prefix],torch.zeros_like(new_mean[:prefix])) or not torch.equal(old_scale[:prefix],torch.ones_like(old_scale[:prefix])) or not torch.equal(new_scale[:prefix],torch.ones_like(new_scale[:prefix])):raise ValueError('Initial actor camera normalization is not identity')
        weight,bias='mlp.body.0.weight','mlp.body.0.bias';old_mean=old_mean[prefix:];old_scale=old_scale[prefix:];new_mean=new_mean[prefix:];new_scale=new_scale[prefix:]
    else:weight,bias='mlp.0.weight','mlp.0.bias'
    # Re-express the same raw-input affine function in the new TRAIN coordinates.
    original=source_model[weight].double()
    result[weight]=(original*(new_scale.double()/old_scale.double())).to(source_model[weight].dtype)
    result[bias]=(source_model[bias].double()+original@((new_mean.double()-old_mean.double())/old_scale.double())).to(source_model[bias].dtype)
    if any(not torch.isfinite(value).all() for value in result.values()):raise ValueError('Initial actor rebasing overflows')
    return result


def initialize_actor(config,policy,info):
    from .train import TrainingConfig,_pins
    from .scenario import decode_json_bytes
    pin=config.data['initial_actor'];validate_initial_actor(pin)
    config_bytes=_read_pin(pin['config'],pin['config_sha256'],1048576)
    source=TrainingConfig.from_dict(decode_json_bytes(config_bytes,1048576));old=source.data;new=config.data
    if old['network']!=new['network'] or old['policy_distribution']!=new['policy_distribution']:raise ValueError('Initial actor encoder or action distribution differs')
    def contracts(data):
        return {(s['observation_schema_hash'],s['action_schema_hash'],s['control_cadence'],s['latency_ticks'],s['settings'].get('fixed_hz')) for s in data['scenarios']}
    if contracts(old)!=contracts(new) or len(contracts(new))!=1 or (info['observation_schema_hash'],info['action_schema_hash'])!=next(iter(contracts(new)))[:2]:raise ValueError('Initial actor observation/action/timing differs')
    checkpoint_bytes=_read_pin(pin['checkpoint'],pin['checkpoint_sha256'],100663296)
    try:state=torch.load(io.BytesIO(checkpoint_bytes),map_location='cpu',weights_only=True)
    except Exception as error:raise ValueError('Initial actor checkpoint cannot be decoded') from error
    if not isinstance(state,dict) or state.get('version')!=1 or state.get('config_hash')!=source.hash or state.get('policy_distribution')!=policy.distribution_id or state.get('environment_restore')!='reset-boundary':raise ValueError('Initial actor checkpoint identity differs')
    parts=_pins(source);expected={name:[manifest.hash for _,manifest in part.recordings] for name,part in parts.items()}
    if state.get('source_pins')!=expected:raise ValueError('Initial actor training source pins differ')
    # Held-out manifests are checked for split lineage; their observations are not read.
    for name,part in parts.items():
        if name!='train':continue
        for path,manifest in part.recordings:
            for chunk in manifest.chunks:_read_pin(Path(path)/chunk.file,chunk.sha256,chunk.bytes)
    normalization=state.get('normalization');model=state.get('model')
    prepared=actor_state_for_normalization(policy,model)
    if normalization is not None:
        if not isinstance(normalization,dict) or not isinstance(normalization.get('source_hash'),str) or not re.fullmatch('[0-9a-f]{64}',normalization['source_hash']) or type(normalization.get('count')) is not int or not 1<=normalization['count']<=10000000 or any(not isinstance(normalization.get(k),(tuple,list)) or len(normalization[k])!=policy.width for k in ['mean','scale']):raise ValueError('Initial actor normalization metadata differs')
        if normalization.get('source_partition')!='train' or normalization.get('observation_schema_hash')!=info['observation_schema_hash'] or 'train' not in parts:raise ValueError('Initial actor normalization is not TRAIN-only')
        if not torch.equal(model['observation_mean'],torch.tensor(normalization['mean'],dtype=torch.float32)) or not torch.equal(model['observation_scale'],torch.tensor(normalization['scale'],dtype=torch.float32)):raise ValueError('Initial actor normalization buffers differ')
    elif not isinstance(model,dict) or not torch.equal(model.get('observation_mean',torch.empty(0)),torch.zeros(policy.width)) or not torch.equal(model.get('observation_scale',torch.empty(0)),torch.ones(policy.width)):raise ValueError('Initial actor identity normalization differs')
    _read_pin(pin['config'],pin['config_sha256'],1048576);_read_pin(pin['checkpoint'],pin['checkpoint_sha256'],100663296)
    policy.load_state_dict(prepared)
    return {'source_config_hash':source.hash,'source_config_sha256':pin['config_sha256'],'source_checkpoint_sha256':pin['checkpoint_sha256'],'source_normalization_hash':None if normalization is None else normalization['source_hash'],'optimizer_reset':True,'critic_reset':True,'recurrent_reset':True,'rng_reset':True,'normalization_rebase':'function-preserving-first-affine-v1'}
