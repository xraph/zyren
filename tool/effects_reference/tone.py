#!/usr/bin/env python3
"""Execute Three r184 tone mapping GLSL using Clang float vectors."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('three',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
source=(args.three/'src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js').read_text()
assert json.loads((args.three/'package.json').read_text())['version']=='0.184.0'
code=source.split('`')[1].replace('uniform float toneMappingExposure;', 'float toneMappingExposure;')
code=re.sub(r'/\*.*?\*/|//[^\n]*','',code,flags=re.S)
code=re.sub(r'\bvec([234])\(',r'V\1(',code)
code=re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',code)
compat=(root/'tool/cloud_reference/compat.hpp').read_text()+r'''
vec3 clamp(vec3 v,float a,float b){return {clamp(v.x,a,b),clamp(v.y,a,b),clamp(v.z,a,b)};}
vec3 max(vec3 v,float n){return {max(v.x,n),max(v.y,n),max(v.z,n)};}
vec3 max(vec3 v,vec3 n){return {max(v.x,n.x),max(v.y,n.y),max(v.z,n.z)};}
vec3 pow(vec3 a,vec3 b){return {std::pow(a.x,b.x),std::pow(a.y,b.y),std::pow(a.z,b.z)};}
vec3 log2(vec3 a){return {std::log2(a.x),std::log2(a.y),std::log2(a.z)};}
vec3 mix(vec3 a,vec3 b,float t){return a*(1-t)+b*t;}
struct mat3 {vec3 x,y,z;mat3(vec3 a,vec3 b,vec3 c):x(a),y(b),z(c){};};
vec3 operator*(mat3 a,vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
'''
main=r'''
int main(){std::cout<<std::setprecision(9)<<"[";int n=0;
vec3 colors[]={V3(0),V3(.001f,.003f,.01f),V3(.18f),V3(1),V3(16,4,.125f),V3(0,4,0),V3(0,0,16),V3(65504,1,32)};
for(auto color:colors)for(float exposure:{.125f,1.f,60.f}){
 toneMappingExposure=exposure;
'''
for name,fn in [('none','Linear'),('reinhard','Reinhard'),('cineon','Cineon'),('acesFilmic','ACESFilmic'),('agx','AgX'),('neutral','Neutral')]:
 main+='''{auto result=%sToneMapping(color);if(n++)std::cout<<',';std::cout<<"{\\"mode\\":\\"%s\\",\\"input\\":["<<color.x<<','<<color.y<<','<<color.z<<"],\\"exposure\\":"<<exposure<<",\\"expected\\":["<<result.x<<','<<result.y<<','<<result.z<<"]}";}\n'''%(fn,name)
main+='}std::cout<<"]";}'
with tempfile.TemporaryDirectory(prefix='zyren-tone-') as temp:
 p=Path(temp);(p/'main.cpp').write_text(compat+code+main);subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True)
 cases=json.loads(subprocess.check_output([str(p/'run')],text=True))
output=root/'test_assets/rendering/effects/tone.json';output.write_text(json.dumps({'reference':'Three.js 0.184.0 tonemapping_pars_fragment','sha256':hashlib.sha256(source.encode()).hexdigest(),'cases':cases},indent=2)+'\n')
print(f'{len(cases)} original GLSL tone mapping cases')
