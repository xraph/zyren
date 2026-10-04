import pytest
from zyren_train.distill import record_teacher
from zyren_train.dataset import DatasetManifest


def test_native_teacher_records_only_camera_and_own_body_from_train(worker,tmp_path):
    result=record_teacher(worker,scenario='guard-visual-depth',seed=7,output=tmp_path/'demo',session_id='visual-teacher')
    assert result['steps']==600 and result['success'] and not result['collision']
    manifest=DatasetManifest.load(tmp_path/'demo')
    assert manifest.partition=='train' and manifest.recording['recording_settings']['teacher_observations_recorded'] is False
    first=next(manifest.records(tmp_path/'demo'))
    assert len(first['observations']['actor'])==14120
    assert set(first).isdisjoint({'teacher_observation','training_only','centralized_state'})
    assert manifest.recording['recording_settings']['chunk_encoding']=='gzip-jsonl-v1'
    with pytest.raises(ValueError,match='identity'):record_teacher(worker,scenario='guard-visual-depth',seed=7,output=tmp_path/'demo',session_id='duplicate')


def test_native_teacher_rejects_heldout_before_writing(worker,tmp_path):
    with pytest.raises(Exception):record_teacher(worker,scenario='guard-visual-depth-evaluation',seed=1001,output=tmp_path/'heldout',session_id='not-training')
    assert not (tmp_path/'heldout').exists()


def test_dagger_preserves_actual_student_actions_and_separate_train_teacher_labels(worker,tmp_path):
    from zyren_train.distill import record_dagger
    import numpy as np
    class Student:
        model_hash='a'*64
        def reset(self):pass
        def act(self,observation,info):return np.asarray([2,2,2,1,0,0],dtype=np.int64)
    path=tmp_path/'dagger'
    result=record_dagger(worker,Student(),scenario='guard-visual-depth',seed=7,output=path,session_id='dagger-teacher',teacher_probability=0)
    manifest=DatasetManifest.load(path);rows=list(manifest.records(path))
    assert result['partition']=='train' and result['steps']==600
    assert manifest.recording['source']=='policy' and manifest.recording['model_hash']=='a'*64
    assert manifest.recording['recording_settings']['label_mode']=='dagger-v1'
    assert rows[0]['applied_actions']['actor']==[2.,2.,2.,1.,0.,0.]
    assert rows[0]['teacher_labels']['actor']!=rows[0]['applied_actions']['actor']
    assert len(rows[0]['observations']['actor'])==14120 and 'teacher_observation' not in rows[0]
    from zyren_train.demonstration import validate_record
    metadata=dict(manifest.recording);metadata['partition']='test'
    with pytest.raises(ValueError,match='TRAIN'):validate_record(rows[0],metadata)
    from zyren_train.policies.cloning import training_sequences
    from zyren_train.dataset import DatasetPartition
    class Policy:nvec=[5,5,5,3,2,2]
    sequence=next(training_sequences(DatasetPartition.from_recordings('train',[path]),Policy()))
    assert sequence[1][0,0].tolist()==rows[0]['teacher_labels']['actor']
    with pytest.raises(Exception):record_dagger(worker,Student(),scenario='guard-visual-depth-evaluation',seed=1001,output=tmp_path/'heldout-dagger',session_id='heldout-dagger',teacher_probability=0)
    assert not (tmp_path/'heldout-dagger').exists()
