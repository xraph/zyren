import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:zyren_game_studio/training.dart';

Future<TrainingRunRequest> processFixture(Directory root, String mode) async {
  final worker = File('${root.path}/worker');
  await worker.writeAsString('fixture-worker');
  final config = File('${root.path}/config-$mode.json');
  await config.writeAsString(
    jsonEncode({
      'worker_sha256': sha256.convert(await worker.readAsBytes()).toString(),
      'mode': mode,
    }),
  );
  final script = File('${root.path}/trainer.py');
  await script.writeAsString(r'''
import sys,json,hashlib,pathlib,signal,time
args=sys.argv; run=pathlib.Path(args[args.index('--run')+1]); config=json.loads(pathlib.Path(args[args.index('--config')+1]).read_text()); mode=config['mode']
if mode=='crash': sys.exit(4)
if mode=='lost': sys.exit(0)
run.mkdir(); seq=0; previous='0'*64; cfg='a'*64; stopped=False
def stop(s,f):
 global stopped
 stopped=True
signal.signal(signal.SIGTERM,stop)
def append(state,**details):
 global seq,previous
 seq+=1; item=dict(details,sequence=seq,previous=previous,config_hash=cfg,state=state)
 b=json.dumps(item,sort_keys=True,separators=(',',':')).encode(); item['sha256']=hashlib.sha256(b).hexdigest(); previous=item['sha256']
 with (run/'receipts.jsonl').open('a') as f: f.write(json.dumps(item,sort_keys=True,separators=(',',':'))+'\n')
append('running',steps=0,updates=0)
if mode=='wait':
 while not stopped: time.sleep(.01)
name='checkpoint-000000000016-00000001.pt'; (run/name).write_bytes(b'checkpoint')
h=hashlib.sha256(b'checkpoint').hexdigest(); (run/'checkpoint.json').write_text(json.dumps(dict(version=1,file=name,sha256=h,steps=16,updates=1,config_hash=cfg)))
append('cancelled' if stopped else 'completed',steps=16,updates=1,checkpoint_sha256=h,workers_closed=True,worker_exit_codes=[0])
if mode=='corrupt':
 p=run/'receipts.jsonl'; p.write_text(p.read_text().replace('"steps":16','"steps":17'))
''');
  return TrainingRunRequest(
    executable: '/usr/bin/python3',
    executableArguments: [script.path],
    projectDirectory: root.path,
    configPath: config.path,
    configFileHash: sha256.convert(await config.readAsBytes()).toString(),
    configHash: 'a' * 64,
    workerPath: worker.path,
    runPath: '${root.path}/runs/$mode',
  );
}
