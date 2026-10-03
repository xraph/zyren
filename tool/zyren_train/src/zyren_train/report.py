"""Immutable evaluation receipts checked against every requested episode."""
from dataclasses import dataclass
import hashlib,json,os,tempfile
from pathlib import Path
from .scenario import canonical_bytes,decode_json_bytes
from .metrics import EpisodeMetric,aggregate
from .regression import TARGETS,qualify


@dataclass(frozen=True)
class EvaluationReport:
    encoded: bytes
    @classmethod
    def from_dict(cls,value):
        from .evaluate import EvaluationPlan
        required={'schema_version','plan','plan_hash','model_hash','family_model_hashes','provider','status','reasons','requested','metrics','episodes','layout_seed_counts','hidden_state_leaks','reward_exploits','stress_coverage','coverage_evidence','worker_failures','worker_exit_codes','worker_sha256','worker_native_sha256','stress_receipt'}
        if not isinstance(value,dict) or set(value)!=required or type(value['schema_version']) is not int or value['schema_version']!=1: raise ValueError('Evaluation report schema differs')
        canonical_bytes(value,16_777_216)
        plan=EvaluationPlan.from_dict(value['plan']);data=plan.data
        if value['plan_hash']!=plan.hash or value['requested']!=plan.requested or value['worker_sha256']!=data['worker_sha256'] or value['worker_native_sha256']!=data['worker_native_sha256']: raise ValueError('Report artifact/plan identity differs')
        if not isinstance(value['model_hash'],str) or not value['model_hash'] or not isinstance(value['provider'],str) or not value['provider'] or set(value['family_model_hashes'])!=set(TARGETS): raise ValueError('Report actor/provider pins missing')
        if any(not isinstance(h,str) or not h for h in value['family_model_hashes'].values()): raise ValueError('Report actor pin differs')
        expected=[(seed,c['scenario']['id'],c['family']) for c in data['cases'] for seed in c['seeds']]
        rows=[EpisodeMetric(**row) for row in value['episodes']]
        if len(rows)!=len(expected) or any((row.index,row.seed,row.scenario,row.family)!=(i,*slot) for i,(row,slot) in enumerate(zip(rows,expected))): raise ValueError('Requested episode coverage differs')
        metrics={f:aggregate([row for row in rows if row.family==f],sum(len(c['seeds']) for c in data['cases'] if c['family']==f)) for f in TARGETS if any(row.family==f for row in rows)}
        seeds={f:len({row.seed for row in rows if row.family==f}) for f in TARGETS}
        if value['metrics']!=metrics or value['layout_seed_counts']!=seeds: raise ValueError('Report aggregate/denominator differs')
        if any(v is not None and (type(v) is not int or v<0) for v in [value['hidden_state_leaks'],value['reward_exploits']]) or type(value['worker_failures']) is not int or value['worker_failures']<0: raise ValueError('Report failure counter differs')
        exits=value['worker_exit_codes']
        if not isinstance(exits,list) or len(exits)>64 or any(code is not None and type(code) is not int for code in exits): raise ValueError('Worker exit receipt differs')
        if not isinstance(value['coverage_evidence'],dict) or any(key not in {c['id'] for c in data['cases']} or not isinstance(labels,list) or any(not isinstance(label,str) for label in labels) for key,labels in value['coverage_evidence'].items()): raise ValueError('Coverage evidence differs')
        for case in data['cases']:
            labels=set(value['coverage_evidence'].get(case['id'],[]));settings=case['scenario']['settings']
            executed=[row for row in rows if row.scenario==case['scenario']['id'] and row.status=='completed']
            permitted=set()
            if settings.get('held_out_layout'):permitted.add('unfamiliar-layouts')
            if settings.get('friction_range'):permitted.add('friction')
            if settings.get('target_speed',0)>0:permitted.add('moving-target')
            if settings.get('curriculum_stage') in ('occlusion','task-combinations'):permitted.add('occlusion-memory')
            if settings.get('curriculum_stage') in ('moving-hazards','task-combinations'):permitted.add('moving-hazards')
            if any(row.fallback_steps>0 for row in executed):
                permitted.add('fallback-recovery')
                if case['stress']['miss_every']:permitted.add('missed-decisions')
                if case['stress']['delay_every']:permitted.add('delayed-observations')
            if labels and (not executed or not labels<=permitted):raise ValueError('Coverage lacks executed scenario evidence')
        coverage=sorted({label for labels in value['coverage_evidence'].values() for label in labels})
        if value['stress_coverage']!=coverage: raise ValueError('Coverage aggregate differs')
        status,reasons=qualify(metrics,hidden_state_leaks=value['hidden_state_leaks'],reward_exploits=value['reward_exploits'],stress_coverage=coverage)
        if any(count<20 for count in seeds.values()):status='failed';reasons.append('fewer than 20 held-out layout seeds')
        if value['worker_failures'] or any(code!=0 for code in exits):status='failed';reasons.append('worker/evaluation failure')
        if status=='passed' and (not exits or any(row.steps<1 for row in rows)): raise ValueError('Passing report lacks native execution evidence')
        if value['status']!=status or value['reasons']!=reasons: raise ValueError('Report acceptance differs from immutable gate')
        return cls(canonical_bytes(value,16_777_216))
    @property
    def data(self): return json.loads(self.encoded)
    @property
    def hash(self): return hashlib.sha256(self.encoded).hexdigest()
    def write(self,path):
        path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
        temporary=None
        try:
            descriptor,temporary=tempfile.mkstemp(prefix=path.name+'.',suffix='.tmp',dir=path.parent)
            with os.fdopen(descriptor,'wb') as stream:stream.write(self.encoded);stream.flush();os.fsync(stream.fileno())
            os.link(temporary,path)
        except FileExistsError:raise ValueError('Evaluation receipt is immutable') from None
        finally:
            if temporary is not None:Path(temporary).unlink(missing_ok=True)
    @classmethod
    def load(cls,path): return cls.from_dict(decode_json_bytes(Path(path).read_bytes(),16_777_216))
