#!/usr/bin/env python3
"""Evaluate pinned LUT3DEffect GLSL and Three dithering on a float-vector host."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('reference',type=Path);args=parser.parse_args();ref=args.reference.resolve()
root=Path(__file__).resolve().parents[2]
assert json.loads((ref/'postprocessing/package.json').read_text())['version']=='6.39.1'
source=json.loads(subprocess.check_output(['node','--input-type=module','-e',"import {LUT3DEffect,LookupTexture} from './postprocessing/build/index.js';console.log(JSON.stringify(new LUT3DEffect(new LookupTexture(new Uint8Array(256),4)).getFragmentShader()));"],cwd=ref,text=True))
def translate(s):
 s=re.sub(r'/\*.*?\*/|//[^\n]*','',s,flags=re.S)
 s=re.sub(r'\b(?:uniform|highp|mediump|lowp|in)\s+','',s)
 s=s.replace('out vec4 outputColor','vec4 &outputColor')
 s=re.sub(r'\bvec([234])\(',r'V\1(',s)
 return re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',s)
compat=(root/'tool/cloud_reference/compat.hpp').read_text()+r'''
using sampler3D=int;
vec3 mix(vec3 a,vec3 b,float t){return a*(1-t)+b*t;}
vec3 clamp(vec3 v,float a,float b){return {clamp(v.x,a,b),clamp(v.y,a,b),clamp(v.z,a,b)};}
struct mat4{vec4 x,y,z,w;mat4(vec4 a,vec4 b,vec4 c,vec4 d):x(a),y(b),z(c),w(d){};};
vec4 operator*(vec4 a,mat4 b){return V4(dot(a,b.x),dot(a,b.y),dot(a,b.z),dot(a,b.w));}
vec4 voxel(int r,int g,int b){r=clamp(r,0,3);g=clamp(g,0,3);b=clamp(b,0,3);return V4((r*g*23+b*71)%256,(g*b*39+r*63)%256,(r*b*47+g*57)%256,255)/255.f;}
vec4 texture(sampler3D image,vec3 uv){vec3 p=uv*4.f-.5f,b=floor(p),f=fract(p);
vec4 v=V4(0);for(int z=0;z<2;z++)for(int y=0;y<2;y++)for(int x=0;x<2;x++)v+=voxel(b.x+x,b.y+y,b.z+z)*(x?f.x:1-f.x)*(y?f.y:1-f.y)*(z?f.z:1-f.z);return v;}
void values(vec4 v){for(int k=0;k<4;k++){if(k)std::cout<<',';std::cout<<v[k];}}
'''
cases=[]
for mode in ['trilinear','tetrahedral']:
 code=compat+'\n#define LUT_3D\n#define LUT_TEXEL_WIDTH .25f\n'+ ('#define TETRAHEDRAL_INTERPOLATION\n' if mode=='tetrahedral' else '')+translate(source)
 code+='\nint main(){scale=V3('+('3' if mode=='tetrahedral' else '.75f')+');offset=V3('+('0' if mode=='tetrahedral' else '.125f')+');'
 code+=r'''
std::cout<<std::setprecision(9)<<"[";
for(int i=0;i<96;i++){vec4 c=V4((i%7)/6.f,(i%11)/10.f,(i%13)/12.f,1);vec4 result;mainImage(c,V2(0),result);if(i)std::cout<<',';std::cout<<"{\"input\":[";values(c);std::cout<<"],\"expected\":[";values(result);std::cout<<"]}";}std::cout<<"]";}
'''
 with tempfile.TemporaryDirectory() as t:
  p=Path(t);(p/'main.cpp').write_text(code);subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True);cases.extend(dict(c,mode=mode) for c in json.loads(subprocess.check_output([str(p/'run')],text=True)))
out=root/'packages/zyren_effects/test/fixtures';out.mkdir(exist_ok=True)
(out/'hald.json').write_text(json.dumps({'reference':'postprocessing 6.39.1 LUT3DEffect','sha256':hashlib.sha256(source.encode()).hexdigest(),'cases':cases},indent=2)+'\n')
three=ref/'node_modules/three/src/renderers/shaders/ShaderChunk'
dither=(three/'dithering_pars_fragment.glsl.js').read_text().split('`')[1]
common=(three/'common.glsl.js').read_text();rand=common[common.index('highp float rand('):common.index('#ifdef HIGH_PRECISION')]
code=compat+'\n#define DITHERING\n#define PI 3.141592653589793f\nvec4 gl_FragCoord;\n'+translate(rand+dither)
code+=r'''
int main(){std::cout<<std::setprecision(9)<<"[";for(int i=0;i<32;i++){gl_FragCoord=V4((i%8)+.5f,(i/8)+.5f,0,1);auto v=dithering(V3(.001f,.01f,.18f));if(i)std::cout<<',';std::cout<<'[';values(V4(v,1));std::cout<<']';}std::cout<<']';}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'main.cpp').write_text(code);subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True);pixels=json.loads(subprocess.check_output([str(p/'run')],text=True))
(out/'dither.json').write_text(json.dumps({'reference':'Three.js 0.184.0 dithering and rand GLSL','sha256':hashlib.sha256((rand+dither).encode()).hexdigest(),'width':8,'height':4,'input':[.001,.01,.18],'pixels':pixels},indent=2)+'\n')
print(f'{len(cases)} original LUT GLSL cases and {len(pixels)} original dither pixels')
