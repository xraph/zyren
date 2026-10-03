import pytest
from zyren_train.scenario import ScenarioSpec


def spec(**changes):
    return ScenarioSpec.from_dict(dict(schema_version=1, id='guard', partition='train',
        game_build_hash='build', observation_schema_hash='obs', action_schema_hash='act',
        callback_id='guard.pursuit', reward_terms=[{'id':'task.progress', 'cap':1.0}],
        seed=7, max_steps=100, control_cadence=1, latency_ticks=1,
        assets=[{'id':'arena','source':'authored','license':'CC0-1.0','hash':'asset'}],
        settings={'occlusion':True}, **changes))


def test_canonical_scenario_hash_and_registered_ids():
    a=spec(); b=ScenarioSpec.from_dict(a.to_dict())
    assert a.hash == b.hash
    assert a.callback_id == 'guard.pursuit'
    with pytest.raises(ValueError):
        ScenarioSpec.from_dict({**a.to_dict(), 'callback_id':'lambda: run()'})


@pytest.mark.parametrize('field,value', [('schema_version',2),('max_steps',0),
    ('partition','other'),('latency_ticks',-1),('assets',[{'id':'a'}])])
def test_invalid_scenario(field,value):
    with pytest.raises(ValueError):
        ScenarioSpec.from_dict({**spec().to_dict(),field:value})


def test_seed_split_or_name_cannot_hide_duplicate_scenario_content():
    a=spec()
    b=ScenarioSpec.from_dict({**a.to_dict(),'id':'copy','seed':100,'partition':'test'})
    assert a.hash==b.hash
