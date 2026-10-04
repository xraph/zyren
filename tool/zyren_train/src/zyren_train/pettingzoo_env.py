"""Parallel-agent adapter to one shared native simulation and framed worker."""
import copy
import numpy as np
import gymnasium as gym
from pettingzoo import ParallelEnv
from .protocol import ProtocolError
from .worker import WorkerFailed


class ZyrenParallelEnv(ParallelEnv):
    metadata={'name':'zyren-native-parallel-v1','render_modes':[], 'is_parallelizable':True}
    def __init__(self,worker,*,scenario,possible_agents,observation_width,action_space,
                 environment_id='parallel',purpose='training'):
        if not isinstance(possible_agents,(list,tuple)) or not 1<=len(possible_agents)<=64 or len(set(possible_agents))!=len(possible_agents) or not all(isinstance(a,str) and a for a in possible_agents):raise ValueError('Bounded declared actor identities required')
        if type(observation_width) is not int or not 1<=observation_width<=131072:raise ValueError('Observation budget differs')
        self.worker=worker;self.scenario=scenario;self.environment_id=environment_id;self.purpose=purpose
        self.possible_agents=list(possible_agents);self.agents=[];self._closed=False;self._failed=False;self._header=None;self._pins=None;self._done=set();self._generations={}
        self._action_contract=copy.deepcopy(action_space)
        if action_space.get('kind')=='multi_discrete':
            values=action_space.get('nvec')
            if not isinstance(values,list) or not values or any(type(n) is not int or not 1<=n<=256 for n in values):raise ValueError('Action branches differ')
            space=gym.spaces.MultiDiscrete(values)
        elif action_space.get('kind')=='box':
            low=np.asarray(action_space.get('low'),dtype=np.float32);high=np.asarray(action_space.get('high'),dtype=np.float32)
            if low.ndim!=1 or not 1<=len(low)<=128 or low.shape!=high.shape or not np.isfinite(low).all() or not np.isfinite(high).all() or (low>=high).any():raise ValueError('Action bounds differ')
            space=gym.spaces.Box(low,high,dtype=np.float32)
        else:raise ValueError('Action contract required')
        self.action_spaces={a:copy.deepcopy(space) for a in self.possible_agents}
        self.observation_spaces={a:gym.spaces.Box(-np.inf,np.inf,shape=(observation_width,),dtype=np.float32) for a in self.possible_agents}
        self._centralized=None
    def observation_space(self,agent):return self.observation_spaces[agent]
    def action_space(self,agent):return self.action_spaces[agent]
    def _read(self,frame):
        h=frame.header;actors=h.get('actor_ids');generations=h.get('actor_generations')
        if not isinstance(actors,list) or not actors or len(set(actors))!=len(actors) or not set(actors)<=set(self.possible_agents) or not isinstance(generations,dict) or set(generations)!=set(actors) or any(type(v) is not int or v<1 for v in generations.values()) or h.get('environment_id')!=self.environment_id:
            raise ProtocolError('Parallel actor identity differs')
        if set(actors)&self._done:raise ProtocolError('Finished actor cannot reenter an episode')
        for a in actors:
            if a in self._generations and generations[a]!=self._generations[a]:raise ProtocolError('Actor generation changed inside episode')
        pins=tuple(h.get(k) for k in ('observation_schema_hash','action_schema_hash','build_id'))
        if any(not isinstance(p,str) or not p for p in pins) or self._pins is not None and pins!=self._pins or h.get('action_space')!=self._action_contract:raise ProtocolError('Parallel schema/build/action pins differ')
        if h.get('split')!=self.purpose:raise ProtocolError('Parallel split differs')
        schema=h.get('observation_schema');fields=schema.get('fields') if isinstance(schema,dict) else None
        forbidden={'state','teacher_action','teacher_actions','teacher_observation','distances','privileged_state'}
        if not isinstance(fields,list) or not 1<=len(fields)<=128 or any(not isinstance(f,dict) or f.get('id',f.get('name')) in forbidden or type(f.get('width')) is not int or not 1<=f['width']<=65536 for f in fields) or sum(f['width'] for f in fields)!=self.observation_space(actors[0]).shape[0]:
            raise ProtocolError('Teacher-only or invalid actor observation fields')
        observations={}
        for a in actors:
            value=frame.array('observation.'+a)
            if value.dtype!=np.dtype('<f4') or value.shape!=self.observation_space(a).shape or not np.isfinite(value).all():raise ProtocolError('Parallel observation shape differs')
            observations[a]=value.copy()
        centralized=h.get('training_only',{})
        if not isinstance(centralized,dict):raise ProtocolError('Centralized data boundary differs')
        self._centralized=copy.deepcopy(centralized);self._pins=pins;self._generations.update(generations);self._header=dict(h)
        info={a:{'tick':h['tick'],'episode_id':h['episode_id'],'actor_generation':generations[a],
                 'observation_schema_hash':pins[0],'action_schema_hash':pins[1],'build_id':pins[2],
                 'legality':copy.deepcopy(h.get('per_agent_legality',{}).get(a))} for a in actors}
        return observations,info
    def reset(self,seed=None,options=None):
        if self._closed:raise WorkerFailed('Parallel environment closed')
        if seed is None:seed=int(np.random.default_rng().integers(0,2**31))
        if type(seed) is not int or not 0<=seed<2**31:raise ValueError('Reset seed differs')
        self._failed=True;self._done.clear();self._generations.clear()
        frame=self.worker.call('reset',environment_id=self.environment_id,episode_id='reset',actor_ids=[],tick=0,
            extra={'seed':seed,'scenario':(options or {}).get('scenario',self.scenario),'purpose':self.purpose})
        observations,info=self._read(frame);self.agents=list(observations);self._failed=False
        return observations,info
    def step(self,actions):
        if self._failed:raise WorkerFailed('Parallel environment needs reset after failure')
        try:return self._step(actions)
        except (ProtocolError,WorkerFailed):
            self._failed=True;raise
    def _step(self,actions):
        if self._closed or self._header is None:raise WorkerFailed('Parallel environment needs reset')
        if not self.agents:
            if actions:raise ValueError('Dead-agent actions are forbidden')
            return {},{},{},{},{}
        if not isinstance(actions,dict) or set(actions)!=set(self.agents):raise ValueError('One action for every live actor is required')
        arrays={}
        for a,value in actions.items():
            if not self.action_space(a).contains(value):raise ValueError('Parallel action outside pinned space')
            arrays['action.'+a]=np.asarray(value,dtype='<f4')
        old=list(self.agents);before=self._header
        frame=self.worker.call('step',environment_id=self.environment_id,episode_id=before['episode_id'],actor_ids=old,
            actor_generations={a:self._generations[a] for a in old},tick=before['tick'],arrays=arrays)
        if frame.header.get('episode_id')!=before['episode_id'] or frame.header.get('tick')!=before['tick']+1:raise ProtocolError('Parallel completed tick differs')
        observations,infos=self._read(frame);h=frame.header
        rewards=h.get('per_agent_rewards');terminated=h.get('per_agent_terminated');truncated=h.get('per_agent_truncated')
        union=set(old)|set(observations)
        if any(not isinstance(m,dict) or set(m)!=union for m in (rewards,terminated,truncated)):raise ProtocolError('Per-agent outcomes differ')
        if any(type(v) not in (int,float) or not np.isfinite(v) for v in rewards.values()) or any(type(v) is not bool for m in (terminated,truncated) for v in m.values()):raise ProtocolError('Per-agent outcome values differ')
        for a in union:
            if a not in observations and not (terminated[a] or truncated[a]):raise ProtocolError('Removed actor needs terminal outcome')
            infos.setdefault(a,{'tick':h['tick'],'episode_id':h['episode_id'],'actor_generation':self._generations[a]})
        removed=set(old)-set(observations)
        terminal=h.get('terminal_observations',{})
        if not isinstance(terminal,dict) or set(terminal)!=removed:raise ProtocolError('Departing actor observation differs')
        for a in removed:
            value=np.asarray(terminal[a],dtype=np.float32)
            if value.shape!=self.observation_space(a).shape or not np.isfinite(value).all():raise ProtocolError('Terminal observation shape differs')
            observations[a]=value.copy()
        ended={a for a in union if terminated[a] or truncated[a]};self._done.update(ended)
        self.agents=[a for a in observations if a not in ended]
        return observations,{a:float(v) for a,v in rewards.items()},dict(terminated),dict(truncated),infos
    def state(self):
        if self._centralized is None:raise RuntimeError('Reset required')
        values=self._centralized.get('state')
        result=np.asarray(values,dtype=np.float32)
        if result.ndim!=1 or not 1<=len(result)<=4096 or not np.isfinite(result).all():raise ProtocolError('Centralized state differs')
        return result.copy()
    @property
    def training_only(self):return copy.deepcopy(self._centralized)
    def close(self):
        if self._closed:return
        self._closed=True
        if self._header is not None:
            self.worker.call('close',environment_id=self.environment_id,episode_id=self._header['episode_id'],actor_ids=list(self._header['actor_ids']),actor_generations=self._header['actor_generations'],tick=self._header['tick'])
        self.agents=[]
