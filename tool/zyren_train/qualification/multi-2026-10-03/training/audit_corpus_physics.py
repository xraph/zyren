"""Audit retained TRAIN prefix signals without claiming missing native poses."""
import hashlib
import json
from pathlib import Path
from zyren_train.dataset import DatasetManifest
from zyren_train.scenario import canonical_bytes
from run_dev_selection import source_hashes

HERE=Path(__file__).resolve().parent
SPAWN_Y=.81;CAPSULE_EXTENT=.8;FIXED_HZ=50;VELOCITY_SCALE=10


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def audit(path):
    manifest=DatasetManifest.load(path);actors={};rows=0;fields=set();previous=None
    for row in manifest.records(path):
        fields.update(row);rows+=1
        if previous is not None and row['tick']!=previous+1:raise ValueError('Retained prefix ticks are not contiguous')
        previous=row['tick']
        for actor,obs in row['observations'].items():
            state=actors.setdefault(actor,{'samples':0,'known_y_velocity':0,'negative_y_velocity_samples':0,
                'min_y_velocity':None,'max_y_velocity':None,'conditional_y':SPAWN_Y,
                'conditional_min_y':SPAWN_Y,'conditional_max_y':SPAWN_Y,'velocity_integration_known':True,
                'static_goal_height_samples':0,'static_goal_min_y':None,'static_goal_max_y':None,
                'maximum_anchor_integration_difference':None,'grounding_known_samples':0})
            if len(obs)!=36 or row['applied_actions'][actor][2:4]!=[2,1]:raise ValueError('Retained yaw-only profile differs')
            state['samples']+=1;state['grounding_known_samples']+=int(obs[16]==1)
            if obs[14]==1:
                vy=obs[1]*VELOCITY_SCALE;state['known_y_velocity']+=1
                state['negative_y_velocity_samples']+=int(vy<0)
                state['min_y_velocity']=vy if state['min_y_velocity'] is None else min(vy,state['min_y_velocity'])
                state['max_y_velocity']=vy if state['max_y_velocity'] is None else max(vy,state['max_y_velocity'])
                if state['velocity_integration_known']:
                    state['conditional_y']+=vy/FIXED_HZ
                    state['conditional_min_y']=min(state['conditional_min_y'],state['conditional_y'])
                    state['conditional_max_y']=max(state['conditional_max_y'],state['conditional_y'])
            else:state['velocity_integration_known']=False
            if manifest.recording['scenario']['callback_id']=='cooperative.search' and obs[34]==obs[35]==1:
                # The historical target is the authored fixed goal at y=.81.
                # Actors rotate around Y only, so local target Y is world target
                # Y minus observer Y. This is a conditional sampled anchor, not
                # a contact manifold or terminal post-step pose certificate.
                y=SPAWN_Y-obs[31]*15;state['static_goal_height_samples']+=1
                state['static_goal_min_y']=y if state['static_goal_min_y'] is None else min(y,state['static_goal_min_y'])
                state['static_goal_max_y']=y if state['static_goal_max_y'] is None else max(y,state['static_goal_max_y'])
                if state['velocity_integration_known']:
                    delta=abs(y-state['conditional_y']);state['maximum_anchor_integration_difference']=delta if state['maximum_anchor_integration_difference'] is None else max(delta,state['maximum_anchor_integration_difference'])
    for state in actors.values():
        state['conditional_final_sample_y']=state.pop('conditional_y')
    if DatasetManifest.load(path).hash!=manifest.hash:raise ValueError('Retained recording changed')
    return {'recording':path.name,'manifest_hash':manifest.hash,'steps':rows,'actors':actors,'retained_fields':sorted(fields),
            'physical_certificate':'unknown','missing':['absolute_actor_poses','native_contact_manifolds','terminal_post_step_observations']}


def main():
    inputs=HERE/'corpus-v3/data';paths=sorted(inputs.iterdir())
    if len(paths)!=48 or any(p.is_symlink() or not p.is_dir() for p in paths):raise ValueError('Exact retained corpus required')
    sources=source_hashes();script=sha(__file__);rows=[audit(p) for p in paths]
    signals=[a for row in rows for a in row['actors'].values()]
    value={'schema_version':1,'purpose':'retained-train-physics-diagnostic','physical_certificate':'unknown',
           'assumptions':{'authored_spawn_y':SPAWN_Y,'floor_y':0,'capsule_half_height_plus_radius':CAPSULE_EXTENT,
               'fixed_hz':FIXED_HZ,'body_velocity_scale':VELOCITY_SCALE,'rotations':'yaw only',
               'velocity_integral':'conditional from authored pre-first-step spawn; no independent pose stream',
               'static_goal_anchor':'conditional authored fixed goalY .81; historical local Y in cooperative samples only'},
           'recordings':rows,'recording_count':len(rows),'recorded_steps':sum(r['steps'] for r in rows),
           'actor_observations':sum(a['samples'] for a in signals),'known_y_velocity_observations':sum(a['known_y_velocity'] for a in signals),
           'negative_y_velocity_observations':sum(a['negative_y_velocity_samples'] for a in signals),
           'min_y_velocity':min(a['min_y_velocity'] for a in signals),'max_y_velocity':max(a['max_y_velocity'] for a in signals),
           'conditional_min_integrated_y':min(a['conditional_min_y'] for a in signals),'conditional_max_integrated_y':max(a['conditional_max_y'] for a in signals),
           'static_goal_height_samples':sum(a['static_goal_height_samples'] for a in signals),
           'static_goal_min_y':min(a['static_goal_min_y'] for a in signals if a['static_goal_min_y'] is not None),
           'maximum_anchor_integration_difference':max(a['maximum_anchor_integration_difference'] for a in signals if a['maximum_anchor_integration_difference'] is not None),
           'source_hashes':sources,'script_sha256':script,'source_inputs_stable':sources==source_hashes(),
           'corpus_recording_receipts_sha256':sha(HERE/'corpus-v3/recordings.jsonl'),'learned_quality':None}
    if not value['source_inputs_stable']:raise ValueError('Audit source changed')
    output=HERE/'training-diagnostics/retained-physics-prefix.json'
    if output.exists():raise ValueError('Immutable physics audit already exists')
    output.write_bytes(canonical_bytes(value)+b'\n')
    print(json.dumps({k:v for k,v in value.items() if k not in ('recordings','source_hashes')},sort_keys=True),flush=True)


if __name__=='__main__':main()
