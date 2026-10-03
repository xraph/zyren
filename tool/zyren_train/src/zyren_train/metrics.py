"""Episode outcomes retain every requested slot and independent task metrics."""
from dataclasses import dataclass,asdict
import math
from .confidence import wilson


@dataclass(frozen=True)
class EpisodeMetric:
    index: int
    seed: int
    scenario: str
    family: str
    status: str
    success: bool
    collision: bool
    reward: float
    progress: float
    steps: int
    invalid_actions: int = 0
    fallback_steps: int = 0
    error: str | None = None
    def __post_init__(self):
        if not isinstance(self.scenario,str) or not self.scenario or self.family not in ('guard','vehicle') or self.error is not None and (not isinstance(self.error,str) or len(self.error)>1024) or type(self.reward) not in (int,float) or type(self.progress) not in (int,float) or self.fallback_steps>self.steps: raise ValueError('Invalid episode provenance')
        if self.status not in ('completed','failed','cancelled') or any(type(v) is not int or v<0 for v in (self.index,self.seed,self.steps,self.invalid_actions,self.fallback_steps)) or any(type(v) is not bool for v in (self.success,self.collision)) or not math.isfinite(self.reward) or not math.isfinite(self.progress): raise ValueError('Invalid episode outcome')
        if self.success and self.status!='completed': raise ValueError('Failed episode cannot succeed')
    def to_dict(self): return asdict(self)


def aggregate(episodes,requested):
    if not episodes or len(episodes)!=requested or len({e.index for e in episodes})!=requested: raise ValueError('Requested episode coverage differs')
    complete=sum(e.status=='completed' for e in episodes); failed=sum(e.status=='failed' for e in episodes); cancelled=sum(e.status=='cancelled' for e in episodes)
    successes=sum(e.success for e in episodes); collisions=sum(e.collision for e in episodes)
    low,high=wilson(successes,requested); clow,chigh=wilson(collisions,requested)
    return {'requested':requested,'completed':complete,'failed':failed,'cancelled':cancelled,
            'successes':successes,'success_denominator':requested,'success_rate':successes/requested,'success_lower95':low,'success_upper95':high,
            'collisions':collisions,'collision_denominator':requested,'collision_rate':collisions/requested,'collision_lower95':clow,'collision_upper95':chigh,
            'reward_sum':sum(e.reward for e in episodes),'progress_sum':sum(e.progress for e in episodes),
            'invalid_actions':sum(e.invalid_actions for e in episodes),'fallback_steps':sum(e.fallback_steps for e in episodes)}
