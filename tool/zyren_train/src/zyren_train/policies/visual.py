"""Small recurrent camera actor over native CHW pixels and permitted own-body data."""
import torch
from torch import nn
from .structured import StructuredPolicy


class _VisualEncoder(nn.Module):
    def __init__(self,channels,body_width):
        super().__init__();self.channels=channels;self.body_width=body_width
        self.camera=nn.Sequential(nn.Conv2d(channels,8,8,stride=4),nn.ReLU(),
            nn.Conv2d(8,16,4,stride=2),nn.ReLU(),nn.Conv2d(16,32,3),nn.ReLU(),
            nn.Flatten(),nn.Linear(32*7*7,96),nn.Tanh())
        self.body=nn.Sequential(nn.Linear(body_width,32),nn.Tanh())
    def forward(self,observation):
        count=self.channels*84*84
        image=observation[:,:count].reshape(-1,self.channels,84,84)
        return torch.cat((self.camera(image),self.body(observation[:,count:])),dim=-1)


class VisualPolicy(StructuredPolicy):
    def __init__(self,channels,body_width,action_space,*,fallback=None,mean=None,scale=None):
        if type(channels) is not int or channels not in (2,3,5) or type(body_width) is not int or not 1<=body_width<=64:
            raise ValueError('Unsupported native camera/body profile')
        super().__init__(body_width,action_space,fallback=fallback)
        self.channels=channels;self.body_width=body_width;self.width=channels*84*84+body_width
        self.observation_mean=torch.tensor(mean if mean is not None else [0.]*self.width,dtype=torch.float32)
        self.observation_scale=torch.tensor(scale if scale is not None else [1.]*self.width,dtype=torch.float32)
        if self.observation_mean.shape!=(self.width,) or self.observation_scale.shape!=(self.width,) or not torch.isfinite(self.observation_mean).all() or not torch.isfinite(self.observation_scale).all() or not (self.observation_scale>0).all():
            raise ValueError('Visual normalization differs')
        self.mlp=_VisualEncoder(channels,body_width)


    def sequence(self,observations,episode_starts,*,state=None,valid=None):
        if observations.ndim!=3 or observations.shape[-1]!=self.width or episode_starts.shape!=observations.shape[:2] or episode_starts.dtype!=torch.bool or not torch.isfinite(observations).all():raise ValueError('Visual sequence schema differs')
        ticks,batch=observations.shape[:2]
        if not 1<=ticks<=1024 or not 1<=batch<=64 or ticks*batch>8192:raise ValueError('Visual sequence budget exceeded')
        valid=torch.ones_like(episode_starts) if valid is None else valid
        if valid.shape!=episode_starts.shape or valid.dtype!=torch.bool:raise ValueError('Visual padding mask differs')
        state=self.initial_state(batch) if state is None else state
        flat=observations.reshape(-1,self.width)
        features=torch.cat([self.mlp((part-self.observation_mean)/self.observation_scale) for part in flat.split(64)],dim=0).reshape(ticks,batch,128)
        outputs=[];values=[]
        for feature,starts,present in zip(features,episode_starts,valid):
            keep=(~starts).to(feature.dtype).unsqueeze(-1)
            candidate=self.lstm(feature,(state[0]*keep,state[1]*keep))
            state=tuple(torch.where(present[:,None],new,old) for new,old in zip(candidate,state))
            outputs.append(self.action_head(candidate[0]));values.append(self.value_head(candidate[0]).squeeze(-1))
        return torch.stack(outputs),torch.stack(values),state


def create_policy(network,width,action_space,*,observation_schema=None,visual_profile=None,**kwargs):
    if network=={'hidden_sizes':[128,128],'lstm_hidden_size':128}:
        return StructuredPolicy(width,action_space,**kwargs)
    import hashlib,json
    validate_visual_network(network)
    channels=network['channels'];body=network['body_width']
    if width!=channels*84*84+body or body!=8:raise ValueError('Camera generated width differs')
    metadata=visual_profile
    if not isinstance(metadata,dict) or metadata.get('layout')!='CHW-image-then-own-body' or metadata.get('family') not in ('guard','vehicle') or metadata.get('mode') not in ('rgb','depth','combined') or observation_schema is None or [f.get('name') for f in observation_schema.get('fields',[])]!=['camera','own-body']:
        raise ValueError('Native camera observation schema required')
    profile=metadata.get('camera_profile',{})
    expected={'rgb':3,'depth':2,'combined':5}[metadata['mode']]
    fields=observation_schema['fields']
    configuration=hashlib.sha256(json.dumps(metadata,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode()).hexdigest()
    if expected!=channels or metadata.get('channels')!=channels or metadata.get('fixed_hz')!=50 or metadata.get('max_hold_ticks')!=2 or profile.get('width')!=84 or profile.get('height')!=84 or profile.get('layout')!='NCHW' or profile.get('mean')!=[0,0,0] or profile.get('std')!=[1,1,1] or metadata.get('body_fields')!=['localVelocityX','localVelocityY','localVelocityZ','angularVelocityY','height','forwardGoal','lateralGoal','valid'] or metadata.get('goal')!=[1,0] or observation_schema.get('configurationHash')!=configuration or observation_schema.get('id')!=metadata['family']+'-visual-'+metadata['mode']+'-v1' or [f.get('width') for f in fields]!=[channels*84*84,8] or [(f.get('min'),f.get('max'),f.get('offset'),f.get('scale')) for f in fields]!=[(0,1,0,1),(-10000,10000,0,1)] or observation_schema.get('cadenceTicks')!=1 or observation_schema.get('latencyTicks')!=1:
        raise ValueError('Native camera profile differs')
    required={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]} if metadata['family']=='guard' else {'kind':'box','low':[-1,0,0],'high':[1,1,1]}
    if action_space!=required:raise ValueError('Visual controller action mapping differs')
    return VisualPolicy(channels,body,action_space,**kwargs)


def validate_visual_network(network):
    if not isinstance(network,dict) or set(network)!={'architecture','channels','body_width','lstm_hidden_size'} or network['architecture']!='native-camera-cnn-v1' or type(network['channels']) is not int or network['channels'] not in (2,3,5) or type(network['body_width']) is not int or not 1<=network['body_width']<=64 or network['lstm_hidden_size']!=128:
        raise ValueError('Unsupported visual architecture')
