import json
import pytest
from zyren_train.demonstration import DemonstrationRecorder, recover_recording
from zyren_train.dataset import DatasetManifest
from test_scenario import spec


def row(tick, actors=('actor',), end=False):
    return dict(episode_id='ep',tick=tick,actor_generations={a:1 for a in actors},
        observations={a:[tick*.1,1.] for a in actors},
        proposed_actions={a:[0.,1.] for a in actors}, applied_actions={a:[0.,.5] for a in actors},
        fallback={a:False for a in actors},delay_ticks={a:1 for a in actors},
        reward_terms={'task.progress':.1},terminated=end,truncated=False)


def recorder(path, **kw):
    return DemonstrationRecorder(path,scenario=spec(),session_id='session',
        run_id='run',environment_id='env',source='player',model_hash='none',**kw)


def test_actor_join_leave_chunks_and_hashes(tmp_path):
    r=recorder(tmp_path,chunk_records=2)
    r.append(row(1)); r.append(row(2,('actor','guest'))); r.append(row(3,('guest',),True))
    m=r.finalize()
    loaded=DatasetManifest.load(tmp_path)
    assert loaded == m
    assert len(m.chunks)==2 and m.episodes[0].steps==3
    assert len(list(loaded.records(tmp_path)))==3
    f=tmp_path / m.chunks[0].file
    f.write_bytes(f.read_bytes()+b' ')
    with pytest.raises(ValueError,match='hash'):
        list(loaded.records(tmp_path))


def test_interrupted_last_chunk_retained_and_marked(tmp_path):
    r=recorder(tmp_path); r.append(row(1)); r.abort()
    f=tmp_path/'chunk-000000.jsonl'
    with f.open('ab') as stream: stream.write(b'{"partial":')
    receipt=recover_recording(tmp_path)
    assert receipt['status']=='interrupted' and receipt['chunks'][-1]['complete'] is False
    assert receipt['chunks'][-1]['valid_records']==1
    assert f.read_bytes().endswith(b'{"partial":')
    with pytest.raises(ValueError): DatasetManifest.load(tmp_path)


def test_empty_and_unfinished_episode_cannot_finalize(tmp_path):
    r=recorder(tmp_path)
    with pytest.raises(ValueError): r.finalize()
    r.append(row(1))
    with pytest.raises(ValueError): r.finalize()
    r.abort()


def test_sensor_profile_pin_and_duplicate_tick_rejected(tmp_path):
    r=recorder(tmp_path); r.append(row(1))
    with pytest.raises(ValueError): r.append({**row(2), 'observation_schema_hash':'changed'})
    with pytest.raises(ValueError): r.append(row(1))
    r.append(row(2,end=True)); r.finalize()
    manifest=tmp_path/'manifest.json'; data=json.loads(manifest.read_text()); data['schema_version']=2
    manifest.write_text(json.dumps(data))
    with pytest.raises(ValueError): DatasetManifest.load(tmp_path)


def test_tampered_recording_pins_and_deep_manifest_rejected(tmp_path):
    r=recorder(tmp_path); r.append(row(1,end=True)); r.finalize()
    p=tmp_path/'manifest.json'; data=json.loads(p.read_text())
    data['recording']['game_build_hash']='changed'; p.write_text(json.dumps(data))
    with pytest.raises(ValueError): DatasetManifest.load(tmp_path)
    p.write_text('['*100+'0'+']'*100)
    with pytest.raises(ValueError): DatasetManifest.load(tmp_path)


def test_fit_reads_hash_checked_training_sources(tmp_path):
    from zyren_train.dataset import DatasetPartition
    from zyren_train.normalize import ObservationNormalizer
    r=recorder(tmp_path); r.append(row(1)); r.append(row(2,end=True)); r.finalize()
    partition=DatasetPartition.from_recordings('train',[tmp_path])
    normalizer=ObservationNormalizer.fit(partition)
    assert normalizer.count==2 and normalizer.source_partition=='train'
    with pytest.raises(TypeError): partition.recordings[0][1].recording['source']='policy'


def test_partial_storage_write_fault_cannot_publish_success(tmp_path):
    r=recorder(tmp_path); r.append(row(1,end=True)); original=r._stream
    class BrokenWrite:
        def write(self,data): original.write(data[:5]); raise OSError('disk failed')
        def close(self): original.close()
    r._stream=BrokenWrite()
    with pytest.raises(OSError): r.append({**row(2,end=True),'episode_id':'next'})
    with pytest.raises(ValueError): r.finalize()
    assert not (tmp_path/'manifest.json').exists()
    r.abort()
