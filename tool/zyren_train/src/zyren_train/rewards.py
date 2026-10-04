"""Registered bounded host reward terms; outcome counters are independent."""
import math

REGISTERED={'task.progress','task.completion','safety.collision','time.step'}
_UNSET=object()

class RewardLedger:
    def __init__(self,terms,*,derived_rewards=_UNSET):
        self.terms=dict(terms)
        if not self.terms or not self.terms.keys()<=REGISTERED or any(type(cap) not in (int,float) or not math.isfinite(cap) or not 0<cap<=100 for cap in self.terms.values()): raise ValueError('Unknown or uncapped reward')
        self.derived_rewards={}
        if derived_rewards is not _UNSET:
            if not isinstance(derived_rewards,dict) or not derived_rewards or not derived_rewards.keys()<={'safety.collision','task.completion'}: raise ValueError('Derived outcome rewards differ')
            for name,value in derived_rewards.items():
                if name not in self.terms or type(value) not in (int,float) or not math.isfinite(value) or not 0<abs(value)<=self.terms[name] or (value<0)!=(name=='safety.collision'): raise ValueError('Derived outcome reward sign or cap differs')
            self.derived_rewards=dict(derived_rewards)
        self.successes=0; self.collisions=0; self.progress=0.; self._completion=set(); self._last={}
    def apply(self,info,*,environment_id):
        if info.get('worker_failed'): raise RuntimeError('Worker failure is not a successful transition')
        episode=info['episode_id']; tick=info['tick']; identity=(environment_id,episode)
        if type(tick) is not int or tick<=self._last.get(identity,-1): raise ValueError('Duplicate or backwards reward transition')
        terms=info.get('reward_terms',{})
        if not isinstance(terms,dict) or not terms.keys()<=self.terms.keys(): raise ValueError('Unregistered reward term')
        if self.derived_rewards:
            if any(type(info.get(name)) is not bool for name in ('collision','success','terminated','truncated')) or (info['terminated'] and info['truncated']): raise ValueError('Derived rewards require typed current outcome receipts')
            if terms.keys() & self.derived_rewards.keys(): raise ValueError('Host and derived reward term duplicate')
        complete=bool(info.get('success',False)) and bool(info.get('terminated') or info.get('truncated')) and identity not in self._completion
        terms=dict(terms)
        if 'safety.collision' in self.derived_rewards:
            terms['safety.collision']=self.derived_rewards['safety.collision'] if info['collision'] else 0
        if 'task.completion' in self.derived_rewards:
            terms['task.completion']=self.derived_rewards['task.completion'] if complete else 0
        reward=0.
        for name,value in terms.items():
            if type(value) not in (int,float) or not math.isfinite(value): raise ValueError('Nonfinite reward')
            if self.derived_rewards and ((name=='safety.collision' and value>0) or (name=='task.completion' and value<0)):raise ValueError('Outcome reward sign differs')
            cap=self.terms[name]; reward+=max(-cap,min(cap,value))
        progress=max(-self.terms.get('task.progress',0),min(self.terms.get('task.progress',0),terms.get('task.progress',0)))
        # Reject the complete transition before consuming its tick or counters.
        self._last[identity]=tick
        self.progress+=progress
        self.collisions+=int(bool(info.get('collision',False)))
        if complete:
            self.successes+=1; self._completion.add(identity)
        # Bound state to currently active episodes, never remember every historical tick.
        for key in list(self._last):
            if key[0]==environment_id and key!=identity: self._last.pop(key); self._completion.discard(key)
        return reward
    def snapshot(self): return {'successes':self.successes,'collisions':self.collisions,'progress':self.progress}
