"""Explicit local budgets and an opt-in remote transport for the same trainer CLI."""
from dataclasses import dataclass,asdict
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import threading
import time
from urllib.parse import urlparse
from urllib.request import Request,build_opener,HTTPRedirectHandler
from .scenario import canonical_bytes,decode_json_bytes


@dataclass(frozen=True)
class RunnerBudget:
    cpu_threads:int
    camera_workers:int
    memory_mib:int
    disk_mib:int
    def __post_init__(self):
        for name,low,high in [('cpu_threads',1,8),('camera_workers',0,8),('memory_mib',256,65536),('disk_mib',128,65536)]:
            value=getattr(self,name)
            if type(value) is not int or not low<=value<=high:raise ValueError('Runner resource budget differs')


class LocalProcessRunner:
    def __init__(self,budget):
        if not isinstance(budget,RunnerBudget):raise ValueError('Explicit runner budget required')
        self.budget=budget;self._owner=threading.Lock()
    def run(self,command,*,cwd,output,timeout):
        if not isinstance(command,(list,tuple)) or not 1<=len(command)<=64 or any(not isinstance(s,str) or not s or len(s)>4096 for s in command) or type(timeout) not in (int,float) or not 0<timeout<=86400:raise ValueError('Explicit bounded argument array and timeout required')
        cwd=Path(cwd).resolve();output=Path(output).absolute()
        if not cwd.is_dir() or output.is_symlink():raise ValueError('Runner paths differ')
        if not self._owner.acquire(blocking=False):raise ValueError('Local process budget is already owned')
        process=None;reason=None;logs=[bytearray(),bytearray()];overflow=threading.Event();threads=[];start=time.monotonic();disk=0
        def signal_group(kind):
            if process is not None:
                try:os.killpg(process.pid,kind)
                except ProcessLookupError:pass
        def capture(stream,target):
            try:
                while data:=stream.read(4096):
                    if len(target)+len(data)>65536:
                        target.extend(data[:max(0,65536-len(target))]);overflow.set();signal_group(signal.SIGKILL);break
                    target.extend(data)
            finally:stream.close()
        def output_size():
            total=count=0
            if output.exists():
                for path in output.rglob('*'):
                    count+=1
                    if count>10000 or path.is_symlink():raise ValueError('output-path')
                    try:
                        if path.is_file():total+=path.stat().st_size
                    except FileNotFoundError:pass
                    if total>self.budget.disk_mib*1048576:raise ValueError('disk-budget')
            return total
        try:
            environment=dict(os.environ)
            for key in ('OMP_NUM_THREADS','MKL_NUM_THREADS','OPENBLAS_NUM_THREADS'):environment[key]=str(self.budget.cpu_threads)
            process=subprocess.Popen(list(command),cwd=cwd,env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            for stream,target in zip((process.stdout,process.stderr),logs):
                thread=threading.Thread(target=capture,args=(stream,target),daemon=True);thread.start();threads.append(thread)
            while process.poll() is None:
                if overflow.is_set():reason='output-budget';break
                if time.monotonic()-start>=timeout:reason='deadline';signal_group(signal.SIGINT);break
                try:disk=output_size()
                except ValueError as error:reason=str(error);signal_group(signal.SIGKILL);break
                time.sleep(.02)
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:signal_group(signal.SIGKILL);process.wait(timeout=5)
            for thread in threads:thread.join(timeout=5)
            if any(thread.is_alive() for thread in threads):
                signal_group(signal.SIGKILL);reason='output-drain'
                for thread in threads:thread.join(timeout=2)
                if any(thread.is_alive() for thread in threads):raise RuntimeError('Runner output did not drain')
            try:disk=output_size()
            except ValueError as error:reason=str(error)
            if overflow.is_set():reason='output-budget'
            result={'schema_version':1,'backend':'local-process','state':'cancelled' if reason=='deadline' else 'failed' if reason or process.returncode!=0 else 'completed','reason':reason,'exit_code':process.returncode,'command':list(command),'cwd':str(cwd),'duration_seconds':time.monotonic()-start,'stdout':logs[0].decode(errors='replace'),'stderr':logs[1].decode(errors='replace'),'resource_budget':asdict(self.budget),'disk_observed_bytes':disk,'memory_qualification':None,'resource_enforcement':'thread-admission/output/disk/deadline; memory is declared, not enforced or measured','live_processes':int(process.poll() is None)}
            result['sha256']=hashlib.sha256(canonical_bytes(result,262144)).hexdigest();return result
        finally:
            if process is not None and process.poll() is None:signal_group(signal.SIGKILL);process.wait(timeout=5)
            self._owner.release()


class RemoteRunner:
    def __init__(self,configuration):
        if not isinstance(configuration,dict) or set(configuration)!={'base_url','authorization'}:raise ValueError('Remote runner must be explicitly configured')
        url=urlparse(configuration['base_url'])
        if url.scheme!='https' or not url.hostname or url.username or url.password or url.query or url.fragment:raise ValueError('Remote runner requires an explicit HTTPS endpoint')
        if not isinstance(configuration['authorization'],str) or not configuration['authorization'] or len(configuration['authorization'])>4096:raise ValueError('Remote authorization differs')
        self.base_url=configuration['base_url'].rstrip('/');self._authorization=configuration['authorization']
    def _request(self,endpoint,data):
        body=canonical_bytes(data,65536)
        request=Request(self.base_url+endpoint,data=body,headers={'Content-Type':'application/json','Authorization':self._authorization},method='POST')
        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self,*args,**kwargs):raise ValueError('Remote endpoint cannot redirect authorization')
        with build_opener(NoRedirect()).open(request,timeout=30) as response:
            value=decode_json_bytes(response.read(65537),65536)
        if not isinstance(value,dict) or value.get('schema_version')!=1 or value.get('config_hash')!=data['config_hash'] or value.get('worker_sha256')!=data['worker_sha256'] or value.get('state') not in ('queued','running','completed','cancelled','failed'):raise ValueError('Remote trainer artifact/protocol receipt differs')
        return value
    def submit(self,*,config,worker_sha256,budget,job_id,resume=False):
        if not isinstance(budget,RunnerBudget) or not isinstance(job_id,str) or not 1<=len(job_id)<=128 or not all(c.isalnum() or c in '-_' for c in job_id):raise ValueError('Remote job identity/budget differs')
        if worker_sha256!=config.data['worker_sha256']:raise ValueError('Remote worker pin differs')
        data={'schema_version':1,'config':config.data,'config_hash':config.hash,'worker_sha256':worker_sha256,'budget':asdict(budget),'job_id':job_id,'resume':bool(resume),'protocol':'zyren-framed-v1'}
        return self._request('/v1/training/submit',data)
