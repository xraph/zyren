"""Episode-boundary curriculum selection over registered native scenario IDs."""
from dataclasses import dataclass

STAGES=('empty-arena','static-obstacles','occlusion','moving-hazards','task-combinations')

@dataclass
class Curriculum:
    stages: tuple
    stage: int = 0
    completed_steps: int = 0
    def __post_init__(self):
        if not self.stages or len(self.stages)>5: raise ValueError('Invalid curriculum stages')
        prior=-1
        for item in self.stages:
            if set(item)!= {'name','scenario','after_steps'} or item['name'] not in STAGES or type(item['after_steps']) is not int or item['after_steps']<=prior or not isinstance(item['scenario'],str): raise ValueError('Invalid curriculum threshold')
            prior=item['after_steps']
        if self.stages[0]['after_steps']!=0: raise ValueError('Curriculum must begin at zero')
    def at_boundary(self,steps):
        if steps<self.completed_steps: raise ValueError('Curriculum cannot rewind')
        self.completed_steps=steps
        self.stage=max(i for i,item in enumerate(self.stages) if steps>=item['after_steps'])
        return self.stages[self.stage]['scenario']
    def snapshot(self): return {'stage':self.stage,'completed_steps':self.completed_steps}
    def restore(self,state):
        if set(state)!= {'stage','completed_steps'} or type(state['completed_steps']) is not int or state['completed_steps']<0: raise ValueError('Invalid curriculum checkpoint')
        self.at_boundary(state['completed_steps'])
        if self.stage!=state['stage']: raise ValueError('Curriculum checkpoint threshold differs')
