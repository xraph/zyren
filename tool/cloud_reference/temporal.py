#!/usr/bin/env python3
"""Evaluate pinned original GLSL variance clipping with Clang float vectors."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('source',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parents[2];folder=Path(__file__).parent
inventory=json.loads((root/'tool/reference/inventory.json').read_text())
path='packages/clouds/src/shaders/varianceClipping.glsl';source=(args.source/path).read_text();digest=hashlib.sha1(f'blob {len(source.encode())}\0'.encode()+source.encode()).hexdigest();assert digest==next(v['gitBlob'] for v in inventory['files'] if v['path']==path)
clip=source[source.index('vec4 clipAABB'):source.index('#ifdef VARIANCE_SAMPLER_ARRAY')]
start=source.index('vec4 varianceClipping(');variance=source[start:source.index('vec4 varianceClipping(',start+10)]
def translate(code):
 code=re.sub(r'/\*.*?\*/|//[^\n]*','',code,flags=re.S)
 code=re.sub(r'\bvec([234])\(',r'V\1(',code)
 code=re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',code)
 return code
code=(folder/'compat.hpp').read_text()+r'''
using ivec2=int __attribute__((ext_vector_type(2)));
vec3 abs(vec3 v){return {abs(v.x),abs(v.y),abs(v.z)};}
vec4 sqrt(vec4 v){return {sqrt(v.x),sqrt(v.y),sqrt(v.z),sqrt(v.w)};}
vec4 max(vec4 v,float n){return {max(v.x,n),max(v.y,n),max(v.z,n),max(v.w,n)};}
vec4 clamp(vec4 v,vec4 a,vec4 b){return {clamp(v.x,a.x,b.x),clamp(v.y,a.y,b.y),clamp(v.z,a.z,b.z),clamp(v.w,a.w,b.w)};}
vec4 neighbors[9];
vec4 texelFetchOffset(int image,ivec2 coord,int mip,ivec2 offset){return neighbors[(offset.y+1)*3+offset.x+1];}
#define VARIANCE_SAMPLER int
#define VARIANCE_SAMPLER_COORD ivec2
#define UNROLLED_LOOP_INDEX 0
const ivec2 varianceOffsets[8]={{-1,-1},{-1,1},{1,-1},{1,1},{1,0},{0,-1},{0,1},{-1,0}};
void values(vec4 v){for(int i=0;i<4;i++){if(i)std::cout<<',';std::cout<<v[i];}}
'''+translate(clip)
outputs=[]
for count in [5,9]:
 offsets='const ivec2 varianceOffsets[8]={{1,0},{0,-1},{0,1},{-1,0},{0,0},{0,0},{0,0},{0,0}};' if count==5 else 'const ivec2 varianceOffsets[8]={{-1,-1},{-1,1},{1,-1},{1,1},{1,0},{0,-1},{0,1},{-1,0}};'
 selected=re.sub(r'const ivec2 varianceOffsets\[8\]=.*?;',offsets,code)+f'\n#define VARIANCE_OFFSET_COUNT {count-1}\n'+translate(variance.replace('i < 8',f'i < {count-1}'))
 selected+=r'''
int main(){std::cout<<std::setprecision(9)<<"[";
for(int i=0;i<32;i++){
 for(int j=0;j<9;j++)neighbors[j]=V4((i%4)*.1f+sin(j*.8f)*.1f,(i%3)*.2f+cos(j*.23f)*.2f,(i%7)*.03f+j*.005f,.2f+j*.02f);
 if(i%8==0)for(int j=0;j<9;j++)neighbors[j]=V4(0);
 vec4 history=V4((i%4)*.2f,(i%5)*.25f,(i%3)*.05f,(i%2)*.8f);float gamma=i%2?2:1;
 vec4 expected=varianceClipping(0,(ivec2){1,1},neighbors[4],history,gamma);
 if(i)std::cout<<',';std::cout<<"{\"neighbors\":[";
 for(int j=0;j<9;j++){if(j)std::cout<<',';std::cout<<'[';values(neighbors[j]);std::cout<<']';}
 std::cout<<"],\"history\":[";values(history);std::cout<<"],\"gamma\":"<<gamma<<",\"expected\":[";values(expected);std::cout<<"]}";
}std::cout<<"]";}
'''
 with tempfile.TemporaryDirectory(prefix='zyren-cloud-temporal-') as temp:
  p=Path(temp);(p/'main.cpp').write_text(selected);subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True)
  values=json.loads(subprocess.check_output([str(p/'run')],text=True));outputs.extend(dict(v,count=count) for v in values)
output=root/'packages/zyren_geospatial/test/fixtures/clouds/temporal.json';output.write_text(json.dumps({'revision':inventory['revision'],'sourceFiles':{path:digest},'samples':outputs},indent=2)+'\n')
print(f'{len(outputs)} source temporal clipping cases')
