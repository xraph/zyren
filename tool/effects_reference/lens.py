#!/usr/bin/env python3
"""Run original lens threshold and feature shaders using a float-vector host."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('source',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parents[2];inventory=json.loads((root/'tool/reference/inventory.json').read_text());hashes={}
def read(name):
 path='packages/effects/src/shaders/'+name;source=(args.source/path).read_text();digest=hashlib.sha1(f'blob {len(source.encode())}\0'.encode()+source.encode()).hexdigest();assert digest==next(v['gitBlob'] for v in inventory['files'] if v['path']==path);hashes[path]=digest;return source
def translate(s,main):
 s=re.sub(r'#include[^\n]*|/\*.*?\*/|//[^\n]*','',s,flags=re.S)
 s=re.sub(r'\b(?:uniform|in|out)\s+','',s);s=s.replace('void main()',f'void {main}()')
 s=re.sub(r'\bvec([234])\(',r'V\1(',s)
 return re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',s)
compat=(root/'tool/cloud_reference/compat.hpp').read_text()+r'''
#include <vector>
using sampler2D=int;using bvec3=int __attribute__((ext_vector_type(3)));
vec2 V2(vec2 v){return v;}vec4 V4(vec2 v,float a,float b){return {v.x,v.y,a,b};}
vec2 clamp(vec2 v,float a,float b){return {clamp(v.x,a,b),clamp(v.y,a,b)};}
float length(vec2 v){return std::sqrt(dot(v,v));}float distance(vec2 a,vec2 b){return length(a-b);}
vec2 normalize(vec2 v){return v/length(v);}vec2 fract(vec2 v){return {fract(v.x),fract(v.y)};}
float luminance(vec3 v){return dot(v,V3(.2126f,.7152f,.0722f));}
bool any(bvec3 v){return v.x||v.y||v.z;}bvec3 isnan(vec3 v){return {std::isnan(v.x),std::isnan(v.y),std::isnan(v.z)};}
vec3 position;vec4 gl_Position,gl_FragColor;
int width=16,height=12;std::vector<vec4> pixels;
vec4 texture(int image,vec2 uv){vec2 p=uv*V2(width,height)-.5f;int bx=std::floor(p.x),by=std::floor(p.y);vec2 f=fract(p);vec4 result=V4(0);
for(int j=0;j<2;j++)for(int i=0;i<2;i++){int x=clamp(bx+i,0,width-1),y=clamp(by+j,0,height-1);result+=pixels[(height-1-y)*width+x]*(i?f.x:1-f.x)*(j?f.y:1-f.y);}return result;}
void values(vec4 v){for(int k=0;k<4;k++){if(k)std::cout<<',';std::cout<<v[k];}}
'''
cases=[]
for kind,stem in [('threshold','downsampleThreshold'),('features','lensFlareFeatures')]:
 v=translate(read(stem+'.vert'),'vertexMain');f=translate(read(stem+'.frag'),'fragmentMain')
 declarations=set()
 def declaration(m):
  value=m.group(0)
  if value in declarations:return ''
  declarations.add(value);return value
 code=compat+re.sub(r'(?m)^vec[234] \w+;',declaration,v+f)
 main=r'''
int main(){std::cout<<std::setprecision(9)<<'[';int count=0;
for(int pattern=0;pattern<4;pattern++)for(int setting=0;setting<4;setting++){
 pixels.clear();for(int y=0;y<height;y++)for(int x=0;x<width;x++){
 vec4 v=pattern==0?V4(0,0,0,1):pattern==1?V4(16,12,8,1):pattern==2?V4((x+1)*1.5f,(y+1)*2.f,(x+y+1)*.7f,1):((x==3&&y==2)?V4(64,32,16,1):V4(0,0,0,1));pixels.push_back(v);}
'''
 if kind=='threshold':main+='int w=8,h=6;thresholdLevel=setting<2?10:0;thresholdRange=setting%2?1:.5f;texelSize=V2(1.f/w,1.f/h);'
 else:main+='int w=16,h=12;ghostAmount=setting==0?.001f:(setting==1?.3f:0);haloAmount=setting==0?.001f:(setting==1?0:.2f);chromaticAberration=setting==2?0:10;texelSize=V2(1.f/w,1.f/h);'
 main+=r'''
if(count++)std::cout<<',';std::cout<<"{\"pattern\":"<<pattern<<",\"setting\":"<<setting<<",\"width\":"<<width<<",\"height\":"<<height<<",\"outputWidth\":"<<w<<",\"outputHeight\":"<<h<<",\"input\":[";
for(int i=0;i<pixels.size();i++){if(i)std::cout<<',';values(pixels[i]);}std::cout<<"],\"expected\":[";
for(int y=0;y<h;y++)for(int x=0;x<w;x++){position=V3((x+.5f)/w*2-1,(1-(y+.5f)/h)*2-1,0);gl_FragColor=V4(0);vertexMain();fragmentMain();if(x||y)std::cout<<',';values(gl_FragColor);}std::cout<<"]}";
}std::cout<<']';}
'''
 with tempfile.TemporaryDirectory(prefix='zyren-lens-') as t:
  p=Path(t);(p/'main.cpp').write_text(code+main);subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True)
  cases.extend(dict(c,kind=kind) for c in json.loads(subprocess.check_output([str(p/'run')],text=True)))
(root/'packages/zyren_effects/test/fixtures/lens.json').write_text(json.dumps({'revision':inventory['revision'],'sourceFiles':hashes,'cases':cases})+'\n')
print(f'{len(cases)} original lens vertex/fragment cases')
