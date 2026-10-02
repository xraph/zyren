#!/usr/bin/env python3
"""Run the supplied GLSL on a C++ CPU host. Never part of shipped rendering."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
source=Path('/Users/rexraphael/Work/TwinOS/three-geospatial-main')
shader=source/'packages/atmosphere/src/shaders/bruneton'
inventory=json.loads((root/'tool/reference/inventory.json').read_text())
parser=argparse.ArgumentParser();parser.add_argument('--profile',choices=['balanced','reference'],default='balanced');args=parser.parse_args()
sizes=dict(TRANSMITTANCE_TEXTURE_WIDTH=256,TRANSMITTANCE_TEXTURE_HEIGHT=64,SCATTERING_TEXTURE_R_SIZE=24,SCATTERING_TEXTURE_MU_SIZE=64,SCATTERING_TEXTURE_MU_S_SIZE=24,SCATTERING_TEXTURE_NU_SIZE=8,IRRADIANCE_TEXTURE_WIDTH=64,IRRADIANCE_TEXTURE_HEIGHT=16)
if args.profile=='reference':
 sizes.update(SCATTERING_TEXTURE_R_SIZE=32,SCATTERING_TEXTURE_MU_SIZE=128,SCATTERING_TEXTURE_MU_S_SIZE=32)
text=''.join(f'#define {k} {v}\n' for k,v in sizes.items())+(Path(__file__).parent/'compat.hpp').read_text()
hashes={}
for name in ['common.glsl','precompute.glsl','runtime.glsl']:
 s=(shader/name).read_text(); hashes[name]=hashlib.sha256(s.encode()).hexdigest()
 blob=hashlib.sha1(f'blob {len(s.encode())}\0'.encode()+s.encode()).hexdigest()
 assert next(f['gitBlob'] for f in inventory['files'] if f['path']==f'packages/atmosphere/src/shaders/bruneton/{name}')==blob
 # Only adapt parameter passing and one GLSL array copy. Equations remain intact.
 s=re.sub(r'\b(?:out|inout) (\w+) (\w+)',r'\1& \2',s)
 if name=='runtime.glsl':s=s.split('Luminance3 GetSolarLuminance()',1)[0]
 s=s.replace('DensityProfileLayer layers[2] = profile.layers;', 'const auto& layers = profile.layers;')
 text+=s
text+=(Path(__file__).parent/'driver.cpp').read_text()
with tempfile.TemporaryDirectory(prefix='zyren-atmosphere-oracle-') as d:
 p=Path(d);(p/'main.cpp').write_text(text)
 subprocess.run(['clang++','-O2','-std=c++17',str(p/'main.cpp'),'-o',str(p/'run')],check=True)
 result=json.loads(subprocess.check_output([str(p/'run')],text=True))
 result['source']={'commit':'b012ad06d858fc035d88aacfd73f092f93c994e4','sha256':hashes,'precision':'CPU double; original GLSL equations','sizes':sizes,'orders':4,'samples':{'optical':500,'line':50,'density':16,'irradiance':32}}
 name='scattering-'+args.profile
 out=root/f'packages/zyren_geospatial/test/fixtures/atmosphere/{name}.json'
 lines=['{', '  "source": '+json.dumps(result['source'])+',', '  "tables": {']
 names=list(result['tables'])
 for index,name in enumerate(names):
  lines.append('    '+json.dumps(name)+': [')
  lines.append(',\n'.join('      '+json.dumps(row) for row in result['tables'][name]))
  lines.append('    ]'+(',' if index<len(names)-1 else ''))
 lines.append('  },')
 keys=[key for key in result if key not in ['tables','source']]
 for index,key in enumerate(keys):
  lines.append('  '+json.dumps(key)+': [')
  lines.append(',\n'.join('    '+json.dumps(row) for row in result[key]))
  lines.append('  ]'+(',' if index<len(keys)-1 else ''))
 lines.append('}')
 out.write_text('\n'.join(lines)+'\n')
 print(out)
