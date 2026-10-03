"""Registered bounded host reward terms; outcome counters are independent."""
import math

REGISTERED={'task.progress','task.completion','safety.collision','time.step'}

class RewardLedger:
    def __init__(self,terms):
        self.terms=dict(terms)
        if not self.terms or not self.terms.keys()<=REGISTERED or any(type(cap) not in (int,float) or not math.isfinite(cap) or not 0<cap<=100 for cap in self.terms.values()): raise ValueError('Unknown or uncapped reward')
        self.successes=0; self.collisions=0; self.progress=0.; self._completion=set(); self._last={}
    def apply(self,info,*,environment_id):
        if info.get('worker_failed'): raise RuntimeError('Worker failure is not a successful transition')
        episode=info['episode_id']; tick=info['tick']; identity=(environment_id,episode)
        if type(tick) is not int or tick<=self._last.get(identity,-1): raise ValueError('Duplicate or backwards reward transition')
        self._last[identity]=tick
        terms=info.get('reward_terms',{})
        if not isinstance(terms,dict) or not terms.keys()<=self.terms.keys(): raise ValueError('Unregistered reward term')
        reward=0.
        for name,value in terms.items():
            if type(value) not in (int,float) or not math.isfinite(value): raise ValueError('Nonfinite reward')
            cap=self.terms[name]; reward+=max(-cap,min(cap,value))
        progress=max(-self.terms.get('task.progress',0),min(self.terms.get('task.progress',0),terms.get('task.progress',0)))
        self.progress+=progress
        self.collisions+=int(bool(info.get('collision',False)))
        if bool(info.get('success',False)) and bool(info.get('terminated') or info.get('truncated')) and identity not in self._completion:
            self.successes+=1; self._completion.add(identity)
        # Bound state to currently active episodes, never remember every historical tick.
        for key in list(self._last):
            if key[0]==environment_id and key!=identity: self._last.pop(key); self._completion.discard(key)
        return reward
    def snapshot(self): return {'successes':self.successes,'collisions':self.collisions,'progress':self.progress}
