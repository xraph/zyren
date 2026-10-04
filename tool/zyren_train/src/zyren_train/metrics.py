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
    role: str | None = None
    result: str | None = None
    opponent: str | None = None
    def __post_init__(self):
        if not isinstance(self.scenario,str) or not self.scenario or self.family not in ('guard','vehicle','cooperative-search','competitive-pursuit') or self.error is not None and (not isinstance(self.error,str) or len(self.error)>1024) or type(self.reward) not in (int,float) or type(self.progress) not in (int,float) or self.fallback_steps>self.steps: raise ValueError('Invalid episode provenance')
        if self.status not in ('completed','failed','cancelled') or any(type(v) is not int or v<0 for v in (self.index,self.seed,self.steps,self.invalid_actions,self.fallback_steps)) or any(type(v) is not bool for v in (self.success,self.collision)) or not math.isfinite(self.reward) or not math.isfinite(self.progress): raise ValueError('Invalid episode outcome')
        if self.success and self.status!='completed': raise ValueError('Failed episode cannot succeed')
        if self.family in ('guard','vehicle'):
            if any(v is not None for v in (self.role,self.result,self.opponent)):raise ValueError('Legacy task metadata changed')
        else:
            roles=('joint',) if self.family=='cooperative-search' else ('pursuer','evader')
            if self.role not in roles or self.result not in ('win','draw','loss') or self.success!=(self.result=='win'):raise ValueError('Multi task role/result differs')
            if self.family=='competitive-pursuit' and (not isinstance(self.opponent,str) or not 1<=len(self.opponent)<=128):raise ValueError('Competitive opponent identity required')
            if self.family=='cooperative-search' and self.opponent is not None:raise ValueError('Joint task cannot invent an opponent')
    def to_dict(self):
        value=asdict(self)
        if self.family in ('guard','vehicle'):
            for key in ('role','result','opponent'):value.pop(key)
        return value


def aggregate(episodes,requested):
    if not episodes or len(episodes)!=requested or len({e.index for e in episodes})!=requested: raise ValueError('Requested episode coverage differs')
    complete=sum(e.status=='completed' for e in episodes); failed=sum(e.status=='failed' for e in episodes); cancelled=sum(e.status=='cancelled' for e in episodes)
    successes=sum(e.success for e in episodes); collisions=sum(e.collision for e in episodes)
    low,high=wilson(successes,requested); clow,chigh=wilson(collisions,requested)
    result={'requested':requested,'completed':complete,'failed':failed,'cancelled':cancelled,
            'successes':successes,'success_denominator':requested,'success_rate':successes/requested,'success_lower95':low,'success_upper95':high,
            'collisions':collisions,'collision_denominator':requested,'collision_rate':collisions/requested,'collision_lower95':clow,'collision_upper95':chigh,
            'reward_sum':sum(e.reward for e in episodes),'progress_sum':sum(e.progress for e in episodes),
            'invalid_actions':sum(e.invalid_actions for e in episodes),'fallback_steps':sum(e.fallback_steps for e in episodes)}

    if episodes[0].family in ('cooperative-search','competitive-pursuit'):
        if any(e.family!=episodes[0].family or e.role!=episodes[0].role for e in episodes):raise ValueError('Multi role aggregate differs')
        wins=sum(e.result=='win' for e in episodes);draws=sum(e.result=='draw' for e in episodes);losses=sum(e.result=='loss' for e in episodes)
        result.update(wins=wins,draws=draws,losses=losses,win_denominator=requested,win_rate=wins/requested,win_lower95=low,win_upper95=high)
    return result
