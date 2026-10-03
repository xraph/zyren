"""Append-only, hash-chained local run receipts with explicit final states."""
import hashlib
import json
import os
from pathlib import Path
from .scenario import canonical_bytes, decode_json_bytes


class RunDirectory:
    def __init__(self,path,config_hash,*,resume=False):
        self.path=Path(path); self.config_hash=config_hash; self.sequence=0; self.previous='0'*64
        if resume:
            if not self.path.is_dir(): raise ValueError('Resume run is missing')
            receipts=self.read_receipts()
            if not receipts or receipts[0]['config_hash']!=config_hash or receipts[-1]['state']=='completed': raise ValueError('Run cannot resume with this configuration')
            self.sequence=receipts[-1]['sequence']; self.previous=receipts[-1]['sha256']
        else:
            self.path.mkdir(parents=True,exist_ok=False)
        self._faulted=False
    def acquire(self):
        lock=self.path/'active.json'
        value={'pid':os.getpid(),'config_hash':self.config_hash}
        if lock.exists():
            old=decode_json_bytes(lock.read_bytes(),1024)
            if old.get('config_hash')!=self.config_hash or type(old.get('pid')) is not int or old['pid']<=0: raise ValueError('Run owner identity differs')
            try: os.kill(old['pid'],0)
            except ProcessLookupError: lock.unlink()
            else: raise ValueError('Run already has an active trainer')
        with lock.open('xb') as stream: stream.write(canonical_bytes(value,1024))
        self._owner=value
    def release(self):
        lock=self.path/'active.json'
        if lock.exists() and decode_json_bytes(lock.read_bytes(),1024)==getattr(self,'_owner',None): lock.unlink()
    def read_receipts(self):
        path=self.path/'receipts.jsonl'
        if not path.exists(): return []
        if path.stat().st_size>16_777_216: raise ValueError('Receipt budget exceeded')
        result=[]; previous='0'*64
        for index,line in enumerate(path.read_bytes().splitlines(),1):
            item=decode_json_bytes(line,65536); claimed=item.pop('sha256')
            if item.get('sequence')!=index or item.get('previous')!=previous or item.get('config_hash')!=self.config_hash or hashlib.sha256(canonical_bytes(item,65536)).hexdigest()!=claimed: raise ValueError('Run receipt chain differs')
            item['sha256']=claimed; result.append(item); previous=claimed
        return result
    def append(self,state,**details):
        if self._faulted: raise ValueError('Run receipt storage is faulted')
        if {'sha256','sequence','previous','config_hash','state'} & details.keys(): raise ValueError('Reserved run receipt field')
        if state not in ('running','completed','failed','cancelled'): raise ValueError('Unknown run state')
        value=dict(details,sequence=self.sequence+1,previous=self.previous,config_hash=self.config_hash,state=state)
        data=canonical_bytes(value,65536); value['sha256']=hashlib.sha256(data).hexdigest(); encoded=canonical_bytes(value,65536)+b'\n'
        path=self.path/'receipts.jsonl'
        if self.sequence>=100_000 or (path.exists() and path.stat().st_size+len(encoded)>16_777_216): raise ValueError('Run receipt budget exceeded')
        try:
            with path.open('ab') as stream:
                if stream.write(encoded)!=len(encoded): raise OSError('Partial receipt write')
                stream.flush(); os.fsync(stream.fileno())
        except Exception:
            self._faulted=True; raise
        self.sequence+=1; self.previous=value['sha256']; return value
