"""Audit-only evasion from actor-facing sightings and authored route bounds."""
import hashlib
import inspect
import math
import re
import numpy as np
from .multi_execution import StaleMultiReceipt
from .scenario import canonical_bytes


class MultiPressureTeacher:
    # These are public scenario geometry/route bounds, not a live entity pose.
    ARENA_X=8.;ARENA_Z=9.;ROUTE_BOUND=6.;SPEED=1.5;LOOK_AHEAD=1.2
    SAFE_X=7.6;SAFE_Z=8.6;MEMORY_TICKS=100
    BINS=(-1.,-.5,0.,.5,1.)
    def __init__(self,*,observation_hash,action_hash):
        self.observation_hash=observation_hash;self.action_hash=action_hash;self.states={}
        config={'version':1,'purpose':'train-pressure-audit-only','observation_hash':observation_hash,
                'action_hash':action_hash,'arena_bounds':[self.ARENA_X,self.ARENA_Z],
                'authored_waypoint_bounds':[-self.ROUTE_BOUND,self.ROUTE_BOUND],
                'speed':self.SPEED,'look_ahead':self.LOOK_AHEAD,'safe_inset':.4,'displacement_float32_tolerance':1e-5,
                'memory_ticks':self.MEMORY_TICKS,'historical_value':'direction-only',
                'heading':'last emitted world movement, requires host applied-action equality','cursor':'not observed or reconstructed'}
        self.config_hash=hashlib.sha256(canonical_bytes(config)).hexdigest()
        self.model_hash=hashlib.sha256(inspect.getsource(type(self)).encode()+canonical_bytes(config)).hexdigest()
        self.provider='scripted-permitted-pressure-audit-v1'
    def reset(self):self.states.clear()
    def hidden_snapshot(self,actor):return None
    @classmethod
    def position_bounds(cls,route):
        # For every possible authored waypoint p: own position = p - delta.
        # Enclose all cursors, then intersect the declared legal arena. This
        # interval is deliberately conservative and never an exact own pose.
        return tuple((max(-arena,-cls.ROUTE_BOUND-delta-1e-5),min(arena,cls.ROUTE_BOUND-delta+1e-5))
                     for delta,arena in zip(route,(cls.ARENA_X,cls.ARENA_Z)))
    def act(self,actor,observation,info):
        allowed={'tick','episode_id','actor_generation','observation_schema_hash','action_schema_hash','build_id','legality'}
        if not isinstance(info,dict) or set(info)-allowed or (info.get('observation_schema_hash'),info.get('action_schema_hash'))!=(self.observation_hash,self.action_hash):
            raise ValueError('Pressure teacher actor-only contract differs')
        if not isinstance(actor,str) or not re.fullmatch('[A-Za-z0-9_.:/-]{1,256}',actor) or actor not in self.states and len(self.states)>=64:
            raise ValueError('Pressure teacher identity budget differs')
        if any(type(info.get(k)) is not int or info[k]<1 for k in ('tick','actor_generation')) or not isinstance(info.get('episode_id'),str):
            raise ValueError('Pressure teacher receipt identity differs')
        value=np.asarray(observation,dtype=np.float32)
        if value.shape!=(36,) or not np.isfinite(value).all() or value[26]!=-1 or value[29]!=1:
            raise ValueError('Pressure teacher requires the evader route profile')
        legality=info.get('legality');nvec=(5,5,5,3,2,2)
        if not isinstance(legality,list) or len(legality)!=6 or any(not isinstance(b,list) or len(b)!=n or any(type(v) is not bool for v in b) for b,n in zip(legality,nvec)) or any(not legality[b][a] for b,a in ((2,2),(3,1),(4,0),(5,0))):
            raise ValueError('Pressure teacher typed masks differ')
        identity=(info['episode_id'],info['actor_generation']);saved=self.states.get(actor)
        if saved is not None and saved['identity']==identity and info['tick']<=saved['tick']:raise StaleMultiReceipt('Pressure teacher receipt is stale')
        if saved is None or saved['identity']!=identity:saved={'heading':0.,'direction':None,'seen_tick':None}
        route=(float(value[27])*15,float(value[28])*15);bounds=self.position_bounds(route)
        if any(low>high for low,high in bounds):raise ValueError('Pressure teacher authored bounds differ')
        heading=saved['heading'];direction=saved['direction'];seen=saved['seen_tick']
        if np.all(value[17:20]==1):
            lx,lz=float(value[4])*15,float(value[6])*15
            direction=(lx*math.cos(heading)+lz*math.sin(heading),-lx*math.sin(heading)+lz*math.cos(heading));seen=info['tick']
        elif seen is None or info['tick']-seen>self.MEMORY_TICKS:direction=None;seen=None
        desired=route if direction is None else (-direction[0],-direction[1])
        candidates=[]
        for ix,x in enumerate(self.BINS):
            for iz,z in enumerate(self.BINS):
                length=math.hypot(x,z)
                if math.hypot(*desired)<.4 or length<1 or not legality[0][ix] or not legality[1][iz]:continue
                dx,dz=x/length,z/length;projected=(dx*self.SPEED*self.LOOK_AHEAD,dz*self.SPEED*self.LOOK_AHEAD)
                if any(low+delta < -safe or high+delta > safe for (low,high),delta,safe in zip(bounds,projected,(self.SAFE_X,self.SAFE_Z))):continue
                candidates.append((dx*desired[0]+dz*desired[1],ix,iz))
        if candidates:_,ix,iz=max(candidates)
        else:
            ix=iz=2
            if not legality[0][2] or not legality[1][2]:raise ValueError('Pressure teacher safe fallback is not legal')
        action=np.asarray([ix,iz,2,1,0,0],dtype=np.int64)
        x,z=self.BINS[ix],self.BINS[iz]
        if x or z:heading=math.atan2(x,z)
        self.states[actor]={'identity':identity,'tick':info['tick'],'heading':heading,'direction':direction,'seen_tick':seen,'position_bounds':bounds}
        return action
