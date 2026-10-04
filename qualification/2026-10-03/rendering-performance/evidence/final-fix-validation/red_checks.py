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
check('o2','packages/zyren_native/native/src/renderer/transaction.rs',lambda s:s.replace('        let warm =', '        return action(self);\n        let warm =',1),cargo+['rejected_dynamic']+trail)
check('c1','packages/zyren_native/native/src/renderer.rs',lambda s:s.replace('if screen_source { 2 }','if screen_source { 1 }'),cargo+['scaled_capture_keeps']+trail)
check('c2','packages/zyren_native/native/src/renderer/pbr.wgsl',lambda s:s.replace('vec2<f32>(textureDimensions(screen_depth))/uniforms.viewport.xy','vec2(1.)'),cargo+['scaled_capture_keeps']+trail)
check('o1','packages/zyren_native/native/src/renderer/batching.rs',lambda s:s.replace('            && self.batches.environments == environments','').replace('                    || environments[next] != environments[first]',''),['fvm','dart','test','test/reflection_probes_test.dart','--concurrency=1'],root/'packages/zyren_native')
check('o3','packages/zyren_3d_tiles/lib/src/streamer.dart',lambda s:subprocess.check_output(['git','show','HEAD:packages/zyren_3d_tiles/lib/src/streamer.dart'],text=True),['fvm','dart','test','test/motion_test.dart','--concurrency=1'],root/'packages/zyren_3d_tiles')
check('m1','packages/zyren_geospatial/lib/src/atmosphere/plugin.dart',lambda s:s.replace('rebuildPrepared: !closing','rebuildPrepared: true'),['fvm','dart','test','test/atmosphere_cloud_inputs_test.dart','--concurrency=1'],root/'packages/zyren_geospatial')
