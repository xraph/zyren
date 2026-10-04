"""Bounded frozen checkpoint history with reproducible weighted sampling."""
import hashlib
import json
from pathlib import Path
import random
import re
from .scenario import canonical_bytes


class OpponentPool:
    def __init__(self,max_versions=8,*,seed,purpose='training'):
        if type(max_versions) is not int or not 1<=max_versions<=32 or type(seed) is not int or not 0<=seed<2**31 or purpose not in ('training','evaluation'):raise ValueError('Opponent pool budget differs')
        self.max_versions=max_versions;self.seed=seed;self.purpose=purpose;self._entries={};self._draw=0
    @staticmethod
    def _verify(entry):
        path=Path(entry['path'])
        if not path.is_file() or path.is_symlink() or not 1<=path.stat().st_size<=100_663_296 or hashlib.sha256(path.read_bytes()).hexdigest()!=entry['sha256']:raise ValueError('Frozen opponent artifact differs')
    def add(self,entry):
        required={'version','path','sha256','observation_schema_hash','action_schema_hash','partition','weight'}
        if not isinstance(entry,dict) or set(entry)!=required or not isinstance(entry['version'],str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}',entry['version']):raise ValueError('Opponent identity differs')
        if entry['version'] in self._entries:raise ValueError('Opponent identity already pinned')
        if len(self._entries)>=self.max_versions:raise ValueError('Opponent history budget exceeded')
        if entry['partition'] not in ('train','withheld') or self.purpose=='training' and entry['partition']!='train':raise ValueError('A withheld opponent cannot enter training')
        if type(entry['weight']) not in (int,float) or not 0<entry['weight']<=100 or not isinstance(entry['path'],str) or len(entry['path'])>4096 or any(not isinstance(entry[k],str) or not re.fullmatch('[0-9a-f]{64}',entry[k]) for k in ('sha256','observation_schema_hash','action_schema_hash')):raise ValueError('Opponent policy pins differ')
        if self._entries and any(next(iter(self._entries.values()))[k]!=entry[k] for k in ('observation_schema_hash','action_schema_hash')):raise ValueError('Opponent schema pins differ')
        self._verify(entry);self._entries[entry['version']]=json.loads(canonical_bytes(entry))
    def sample(self):
        entries=[self._entries[k] for k in sorted(self._entries)]
        if not entries:raise ValueError('Opponent history is empty')
        for entry in entries:self._verify(entry)
        draw=random.Random(f'{self.seed}:{self._draw}').random()*sum(e['weight'] for e in entries)
        selected=entries[-1]
        for entry in entries:
            draw-=entry['weight']
            if draw<0:selected=entry;break
        self._draw+=1
        return json.loads(canonical_bytes(selected))
    def to_dict(self):return {'version':1,'max_versions':self.max_versions,'seed':self.seed,'purpose':self.purpose,'draw':self._draw,'entries':[json.loads(canonical_bytes(self._entries[k])) for k in sorted(self._entries)]}
    @classmethod
    def from_dict(cls,data):
        if not isinstance(data,dict) or set(data)!={'version','max_versions','seed','purpose','draw','entries'} or data['version']!=1 or type(data['draw']) is not int or not 0<=data['draw']<=10_000_000 or not isinstance(data['entries'],list):raise ValueError('Opponent history receipt differs')
        pool=cls(data['max_versions'],seed=data['seed'],purpose=data['purpose'])
        for entry in data['entries']:pool.add(entry)
        pool._draw=data['draw'];return pool
