import pytest
from zyren_train.metrics import EpisodeMetric,aggregate
from zyren_train.confidence import wilson


def test_failed_and_cancelled_episodes_remain_in_success_denominator():
    rows=[EpisodeMetric(0,7,'s','guard','completed',True,False,1.,1.,240),EpisodeMetric(1,8,'s','guard','failed',False,False,0.,0.,1),EpisodeMetric(2,9,'s','guard','cancelled',False,False,0.,0.,0)]
    result=aggregate(rows,3)
    assert result['completed']+result['failed']+result['cancelled']==3
    assert result['success_rate']==1/3 and result['success_denominator']==3
    with pytest.raises(ValueError): aggregate(rows[:1],3)
    with pytest.raises(ValueError): EpisodeMetric(0,7,'s','guard','failed',True,False,1.,1.,1)


def test_wilson_boundaries_and_invalid_counts():
    assert wilson(0,200)[0]==0 and wilson(200,200)[1]==1
    assert wilson(190,200)[0]>.90
    for counts in [(0,0),(2,1),(-1,200),(True,200)]:
        with pytest.raises(ValueError): wilson(*counts)
