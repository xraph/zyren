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
