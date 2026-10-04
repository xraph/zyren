import hashlib
import pytest
from zyren_train.opponents import OpponentPool


def pin(path,version,*,partition='train',weight=1):
    return {'version':version,'path':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'observation_schema_hash':'a'*64,'action_schema_hash':'b'*64,'partition':partition,'weight':weight}


def test_bounded_frozen_opponents_are_seeded_and_pinned(tmp_path):
    paths=[tmp_path/f'policy-{i}.pt' for i in range(4)]
    for i,p in enumerate(paths):p.write_bytes(bytes([i])*32)
    pool=OpponentPool(2,seed=7)
    for i,p in enumerate(paths[:2]):pool.add(pin(p,str(i),weight=i+1))
    same=OpponentPool.from_dict(pool.to_dict())
    assert [pool.sample()['version'] for _ in range(20)]==[same.sample()['version'] for _ in range(20)]
    with pytest.raises(ValueError,match='budget'):pool.add(pin(paths[2],'2'))
    with pytest.raises(ValueError,match='identity'):pool.add(pin(paths[2],'0'))
    before=pool.to_dict();paths[0].write_bytes(b'changed')
    with pytest.raises(ValueError,match='artifact'):pool.sample()
    assert pool.to_dict()==before


def test_withheld_opponent_cannot_enter_training_pool(tmp_path):
    p=tmp_path/'fixed.pt';p.write_bytes(b'pinned')
    pool=OpponentPool(4,seed=7)
    with pytest.raises(ValueError,match='withheld'):pool.add(pin(p,'heldout',partition='withheld'))
    pool=OpponentPool(4,seed=7,purpose='evaluation');pool.add(pin(p,'heldout',partition='withheld'))
    assert pool.sample()['version']=='heldout'
