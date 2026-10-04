import pytest
from zyren_train.metrics import EpisodeMetric, aggregate
from zyren_train.regression import MULTI_TARGETS, qualify_multi


def row(i, family='competitive-pursuit', role='pursuer', result='win', opponent='fixed-0', **kwargs):
    return EpisodeMetric(i, i + 7, 'heldout', family, 'completed', result == 'win', False,
                         0., 0., 100, role=role, result=result, opponent=opponent, **kwargs)


def test_competitive_roles_and_losses_do_not_collapse_into_success():
    value = aggregate([row(0), row(1, result='loss'), row(2, result='draw')], 3)
    assert value['wins'] == value['losses'] == value['draws'] == 1
    assert value['win_denominator'] == 3 and value['win_rate'] == 1/3
    with pytest.raises(ValueError): row(0, result='win', role='searcher')
    with pytest.raises(ValueError): row(0, result='pending')
    with pytest.raises(ValueError): row(0, opponent='')


def test_legacy_metric_shape_is_unchanged():
    value = EpisodeMetric(0, 7, 'guard', 'guard', 'completed', True, False, 1., 1., 240).to_dict()
    assert set(value) == {'index','seed','scenario','family','status','success','collision','reward','progress','steps','invalid_actions','fallback_steps','error'}


def test_multi_gates_cannot_hide_a_failed_role_or_an_opponent():
    cooperative = aggregate([row(i, 'cooperative-search', 'joint', opponent=None) for i in range(200)], 200)
    roles = {role: aggregate([row(i, role=role) for i in range(200)], 200) for role in ['pursuer', 'evader']}
    opponents = {role: {f'opponent-{j}': aggregate([row(i, role=role, opponent=f'opponent-{j}') for i in range(50)], 50) for j in range(4)} for role in roles}
    history = {role: {f'history-{j}': aggregate([row(i, role=role, opponent=f'history-{j}') for i in range(50)], 50) for j in range(4)} for role in roles}
    args = dict(hidden_state_leaks=0, reward_exploits=0, worker_failures=0, stale_outputs=0,
                historical=history, previous=None, initial_baseline=True)
    assert qualify_multi(cooperative, roles, opponents, **args)[0] == 'passed'
    roles['evader'] = aggregate([row(i, role='evader', result='loss') for i in range(200)], 200)
    assert qualify_multi(cooperative, roles, opponents, **args)[0] == 'failed'
    roles['evader'] = roles['pursuer']
    history['evader']['history-0']['invalid_actions'] = 1
    assert qualify_multi(cooperative, roles, opponents, **args)[0] == 'failed'
    history['evader']['history-0']['invalid_actions'] = 0
    opponents['pursuer'].pop('opponent-0')
    assert qualify_multi(cooperative, roles, opponents, **args)[0] == 'failed'
    assert MULTI_TARGETS['competitive-pursuit']['per_opponent_win_rate'] == .50
