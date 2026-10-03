"""Pinned game scenario definitions. Callback IDs resolve in the Dart host."""
from dataclasses import dataclass
import hashlib
import json
import math
import re

PARTITIONS = frozenset(('train', 'validation', 'test'))
ID = re.compile(r'^[A-Za-z0-9_.:/-]{1,256}$')


def identifier(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise ValueError('Invalid registered identifier')
    return value


def integer(value, minimum=0, maximum=10_000_000):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError('Invalid bounded integer')
    return value


def canonical_bytes(value, max_bytes=1_048_576):
    pending=[(value,0)]; nodes=0
    while pending:
        current,depth=pending.pop(); nodes+=1
        if depth>32 or nodes>100_000: raise ValueError('Metadata tree exceeds budget')
        if isinstance(current,dict):
            if any(not isinstance(k,str) for k in current): raise ValueError('JSON keys must be strings')
            pending.extend((v,depth+1) for v in current.values())
        elif isinstance(current,(list,tuple)):
            pending.extend((v,depth+1) for v in current)
        elif current is not None and not isinstance(current,(str,bool,int,float)):
            raise ValueError('Unsupported JSON value')
        elif isinstance(current,float) and not math.isfinite(current):
            raise ValueError('Non-finite metadata')
    result=json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
    if len(result)>max_bytes: raise ValueError('Metadata bytes exceed budget')
    return result


def decode_json_bytes(data,max_bytes=1_048_576):
    if len(data)>max_bytes: raise ValueError('JSON bytes exceed budget')
    depth=0; quoted=False; escape=False
    for byte in data:
        if quoted:
            if escape: escape=False
            elif byte==92: escape=True
            elif byte==34: quoted=False
        elif byte==34: quoted=True
        elif byte in (91,123):
            depth+=1
            if depth>32: raise ValueError('JSON depth exceeds budget')
        elif byte in (93,125): depth-=1
    value=json.loads(data); canonical_bytes(value,max_bytes)
    return value


@dataclass(frozen=True)
class ScenarioSpec:
    _encoded: bytes

    @classmethod
    def from_dict(cls,data):
        required={'schema_version','id','partition','game_build_hash','observation_schema_hash',
                  'action_schema_hash','callback_id','reward_terms','seed','max_steps',
                  'control_cadence','latency_ticks','assets','settings'}
        if not isinstance(data,dict) or set(data)!=required or type(data['schema_version']) is not int or data['schema_version']!=1:
            raise ValueError('Unsupported scenario schema')
        for key in ('id','game_build_hash','observation_schema_hash','action_schema_hash','callback_id'):
            identifier(data[key])
        if data['partition'] not in PARTITIONS: raise ValueError('Unknown partition')
        integer(data['seed'],0,2**53-1); integer(data['max_steps'],1)
        integer(data['control_cadence'],1,1000); integer(data['latency_ticks'],0,1000)
        terms=data['reward_terms']; assets=data['assets']
        if not isinstance(terms,list) or not 1<=len(terms)<=64: raise ValueError('Invalid reward terms')
        term_ids=set()
        for term in terms:
            if not isinstance(term,dict) or set(term)!={'id','cap'}: raise ValueError('Invalid reward term')
            identifier(term['id'])
            if term['id'] in term_ids or type(term['cap']) not in (int,float) or not 0<term['cap']<=1000:
                raise ValueError('Invalid reward cap')
            term_ids.add(term['id'])
        if not isinstance(assets,list) or len(assets)>256: raise ValueError('Invalid assets')
        for asset in assets:
            if not isinstance(asset,dict) or set(asset)!={'id','source','license','hash'}:
                raise ValueError('Asset provenance is missing')
            for key in asset: identifier(asset[key])
        if not isinstance(data['settings'],dict): raise ValueError('Invalid scenario settings')
        return cls(canonical_bytes(data,max_bytes=65536))

    def to_dict(self): return json.loads(self._encoded)
    def __getattr__(self,name):
        try: return self.to_dict()[name]
        except KeyError: raise AttributeError(name) from None
    @property
    def hash(self):
        # A renamed copy, seed variation or split label cannot hide shared content.
        content={k:v for k,v in self.to_dict().items() if k not in ('id','partition','seed')}
        return hashlib.sha256(canonical_bytes(content)).hexdigest()
