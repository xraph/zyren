from pathlib import Path
import subprocess,os
root=Path.cwd(); out=root/'.superpowers/sdd/2026-10-03-rendering-performance/final-fix-validation'
env=os.environ|{'CARGO_PROFILE_DEV_DEBUG':'0','CARGO_PROFILE_TEST_DEBUG':'0','CARGO_INCREMENTAL':'0','RUN_NATIVE_GPU':'1'}
def check(label, path, mutate, args,cwd=root):
 p=root/path; original=p.read_text()
 try:
  p.write_text(mutate(original))
  with open(out/(label+'-red.log'),'w') as log:
   log.write('Controlled source mutation of the named fix only. Expected regression failure.\n');log.flush()
   result=subprocess.run(args,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT)
  print(label,result.returncode,flush=True)
 finally: p.write_text(original)
cargo=['cargo','test','--manifest-path','packages/zyren_native/native/Cargo.toml','--lib']
trail=['--','--include-ignored','--test-threads=1','--nocapture']
check('o1-native','packages/zyren_native/native/src/renderer/batching.rs',lambda s:s.replace('            && self.batches.environments == environments','').replace('                    || environments[next] != environments[first]',''),cargo+['probe_assignments']+trail)
check('c2-strong','packages/zyren_native/native/src/renderer/pbr.wgsl',lambda s:s.replace('vec2<f32>(textureDimensions(screen_depth))/uniforms.viewport.xy','vec2(1.)'),cargo+['scaled_capture_keeps']+trail)
