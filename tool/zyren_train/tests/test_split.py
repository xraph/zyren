import pytest
from zyren_train.dataset import EpisodeReceipt, DatasetPartition
from zyren_train.split import split_by_scenario, validate_partitions
from zyren_train.normalize import ObservationNormalizer, ObservationSample


def episode(i,scenario=None,session=None):
    return EpisodeReceipt(episode_id=str(i),scenario_hash=scenario or f's{i}',session_id=session or f'r{i}',
        steps=1,observation_schema_hash='obs',action_schema_hash='act',game_build_hash='build',
        partition=None,source='scripted')


def test_split_by_scenario_and_recording_session():
    rows=[episode(i) for i in range(30)] + [episode(30,'s0','r1')]
    parts=split_by_scenario(rows,seed=7)
    assert {e.episode_id for p in parts.values() for e in p.episodes} == {e.episode_id for e in rows}
    assert parts['train'].scenario_hashes.isdisjoint(parts['test'].scenario_hashes)
    assert parts['train'].session_ids.isdisjoint(parts['validation'].session_ids)
    assert split_by_scenario(rows,seed=7) == parts
    p0=next(k for k,p in parts.items() if 's0' in p.scenario_hashes)
    assert 'r1' in parts[p0].session_ids


def test_cross_partition_hash_and_session_leakage_rejected():
    train=DatasetPartition('train',(episode(0),))
    for other in [episode(1,'s0'),episode(1,session='r0')]:
        with pytest.raises(ValueError): validate_partitions({'train':train,'test':DatasetPartition('test',(other,))})
    with pytest.raises(ValueError): split_by_scenario([])


def test_normalizer_fits_train_only_and_schema_width():
    p=DatasetPartition('train',(episode(0),))
    def samples(rows): return [ObservationSample('r0','0','s0',tuple(v)) for v in rows]
    norm=ObservationNormalizer.fit(p,observations=samples([[1.,2.],[3.,4.]]))
    assert norm.source_partition=='train'
    assert norm.transform([2.,3.])==[0.,0.]
    with pytest.raises(ValueError): ObservationNormalizer.fit(DatasetPartition('test',(episode(0),)), observations=samples([[1.,2.]]))
    with pytest.raises(ValueError): ObservationNormalizer.fit(p,observations=[])
    with pytest.raises(ValueError): ObservationNormalizer.fit(p,observations=samples([[1.],[1.,2.]]))

    with pytest.raises(ValueError): ObservationNormalizer.fit(p,observations=[ObservationSample('heldout','0','s0',(1.,2.))])
