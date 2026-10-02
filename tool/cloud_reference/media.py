#!/usr/bin/env python3
"""Run original cloud media, phase and structured sampling GLSL on Clang floats."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, tempfile
parser=argparse.ArgumentParser();parser.add_argument('source',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parents[2];folder=Path(__file__).parent
inventory=json.loads((root/'tool/reference/inventory.json').read_text())
hashes={v['path']:v['gitBlob'] for v in inventory['files']};loaded={}
def original(name):
 path='packages/clouds/src/shaders/'+name;code=(args.source/path).read_text()
 digest=hashlib.sha1(f'blob {len(code.encode())}\0'.encode()+code.encode()).hexdigest()
 assert digest==hashes[path],path;loaded[path]=digest;return code
def translate(code):
 code=re.sub(r'/\*.*?\*/|//[^\n]*','',code,flags=re.S)
 code=re.sub(r'\bvec([234])\(',r'V\1(',code)
 code=code.replace('bvec3(', 'B3(')
 code=re.sub(r'\b(?:out|inout) (\w+) (\w+)',r'\1& \2',code)
 code=re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',code)
 return code
code=(folder/'compat.hpp').read_text()+r'''
using ivec3=int __attribute__((ext_vector_type(3)));
using bvec3=int __attribute__((ext_vector_type(3)));
using bvec4=int __attribute__((ext_vector_type(4)));
using bvec2=int __attribute__((ext_vector_type(2)));
bvec3 B3(bool a,bool b,bool c){return {int(a),int(b),int(c)};}
vec2 V2(vec2 v){return v;} vec4 V4(vec4 v){return v;}
float length(vec2 v){return sqrt(dot(v,v));} float length(vec3 v){return sqrt(dot(v,v));}
vec2 normalize(vec2 v){return v/length(v);}
vec3 abs(vec3 v){return {abs(v.x),abs(v.y),abs(v.z)};}
vec3 sign(vec3 v){return {v.x<0?-1.f:v.x>0?1.f:0.f,v.y<0?-1.f:v.y>0?1.f:0.f,v.z<0?-1.f:v.z>0?1.f:0.f};}
float atan(float a,float b){return atan2(a,b);}
vec2 max(vec2 a,vec2 b){return {max(a.x,b.x),max(a.y,b.y)};}
vec4 clamp(vec4 v,float a,float b){return {clamp(v.x,a,b),clamp(v.y,a,b),clamp(v.z,a,b),clamp(v.w,a,b)};}
vec4 saturate(vec4 v){return clamp(v,0,1);}
vec4 mix(vec4 a,vec4 b,vec4 t){return a*(1-t)+b*t;}
vec2 pow(vec2 a,vec2 b){return {pow(a.x,b.x),pow(a.y,b.y)};}
vec4 pow(vec4 a,vec4 b){return {pow(a.x,b.x),pow(a.y,b.y),pow(a.z,b.z),pow(a.w,b.w)};}
vec4 exp(vec4 a){return {exp(a.x),exp(a.y),exp(a.z),exp(a.w)};}
vec3 exp(vec3 a){return {exp(a.x),exp(a.y),exp(a.z)};}
vec4 remapClamped(vec4 x,vec4 a,vec4 b){return saturate((x-a)/(b-a));}
bool all(bvec2 v){return v.x&&v.y;} bool any(bvec3 v){return v.x||v.y||v.z;}
bool any(bvec4 v){return v.x||v.y||v.z||v.w;}
bvec4 greaterThan(vec4 a,vec4 b){return a>b;}
bvec2 greaterThan(vec2 a,vec2 b){return a>b;}
bvec3 greaterThan(vec3 a,vec3 b){return a>b;} bvec3 lessThan(vec3 a,vec3 b){return a<b;}
vec2 dFdx(vec2 v){return V2(1,0);}vec2 dFdy(vec2 v){return V2(0,1);}
#define PI 3.14159265358979323846f
#define RECIPROCAL_PI 0.3183098861837907f
#define RECIPROCAL_PI2 0.15915494309189535f
#define RECIPROCAL_PI4 0.07957747154594767f
#define SHAPE_DETAIL
#define TURBULENCE
#define LOCAL_WEATHER_CHANNELS rgba
vec2 resolution=V2(512),localWeatherRepeat=V2(100),localWeatherOffset=V2(.012f,-.024f),turbulenceRepeat=V2(20);
vec3 shapeRepeat=V3(.0003f),shapeOffset=V3(.1f,.2f,.3f),shapeDetailRepeat=V3(.006f),shapeDetailOffset=V3(.2f,.3f,.4f);
float coverage=.6f,scatteringCoefficient=.8f,absorptionCoefficient=.2f,turbulenceDisplacement=350;
vec4 minLayerHeights=V4(750,1000,7500,2000),maxLayerHeights=V4(1400,2200,8000,3200);
vec4 densityScales=V4(.2f,.2f,.003f,.1f),shapeAmounts=V4(1,1,.4f,.6f),shapeDetailAmounts=V4(1,1,0,.5f);
vec4 weatherExponents=V4(1,2,1,.5f),shapeAlteringBiases=V4(.35f),coverageFilterWidths=V4(.6f,.6f,.5f,.7f);
vec3 minIntervalHeights=V3(0,3200,8000),maxIntervalHeights=V3(750,7500,8000);
int localWeatherTexture=0,shapeTexture=1,shapeDetailTexture=2,turbulenceTexture=3;
vec4 weatherValue;float shapeValue,detailValue;vec3 turbulenceValue;
vec4 texture(int id,vec2 uv){return id==0?weatherValue:V4(turbulenceValue,1);}
vec4 texture(int id,vec3 uv){return V4(id==1?shapeValue:detailValue);}
vec4 textureLod(int id,vec2 uv,float mip){return texture(id,uv);}
'''
code+=translate(original('types.glsl'))
code+='CloudDensityProfile densityProfile={V4(0,0,0,.1f),V4(0,0,0,-2),V4(.75f),V4(.25f)};\n'
media=original('clouds.glsl');media=media[media.index('// Straightforward'):]
code+=translate(media)
phase=original('clouds.frag');phase=phase[phase.index('vec2 henyeyGreenstein'):phase.index('float marchOpticalDepth')]
code+='const vec2 scatterAnisotropy=V2(.7f,-.2f);const float scatterAnisotropyMix=.5f;\n'+translate(phase)
code+=translate(original('structuredSampling.glsl'))
baseCode=code
code+=r'''
void scalar(float x){if(std::isfinite(x))std::cout<<x;else std::cout<<"null";}
void values(vec4 v){for(int i=0;i<4;i++){if(i)std::cout<<',';scalar(v[i]);}}
int main(){std::cout<<std::setprecision(9)<<"[";
for(int i=0;i<96;i++){
 float h=500+(i%24)*330.f;vec3 p=normalize(V3(sin(i*1.7f),cos(i*.61f),sin(i*.23f)+.1f))*(6360000+h);
 float mip=(i%4)*.25f,jitter=(i%7)/7.f;
 weatherValue=V4((i%5)/4.f,(i%9)/8.f,(i%3)/2.f,(i%11)/10.f);
 shapeValue=.4f+(i%7)*.1f;detailValue=(i%6)*.2f;turbulenceValue=V3(.2f,.4f,.6f);
 vec2 uv=getGlobeUv(p);auto weather=sampleWeather(uv,h,mip);auto m=sampleMedia(weather,p,uv,mip,jitter);
 vec3 direction=normalize(V3(sin(i*.17f)+.01f,cos(i*.7f)+.02f,.5f));
 vec3 normal=getStructureNormal(direction,jitter);float offset,stepSize;intersectStructuredPlanes(normal,p,direction,100,offset,stepSize);
 if(i)std::cout<<',';std::cout<<"{\"position\":["<<p.x<<','<<p.y<<','<<p.z<<"],\"height\":"<<h<<",\"mip\":"<<mip<<",\"jitter\":"<<jitter;
 std::cout<<",\"weather\":[";values(weatherValue);std::cout<<"],\"shape\":"<<shapeValue<<",\"detail\":"<<detailValue;
 std::cout<<",\"direction\":["<<direction.x<<','<<direction.y<<','<<direction.z<<"],\"expected\":["<<uv.x<<','<<uv.y<<',';
 values(weather.heightFraction);std::cout<<',';values(weather.density);std::cout<<',';values(m.weight);std::cout<<','<<m.scattering<<','<<m.extinction<<',';
 std::cout<<phaseFunction(-1+2*(i/95.f))<<','<<normal.x<<','<<normal.y<<','<<normal.z<<','<<offset<<','<<stepSize<<"]}";
}std::cout<<"]";}
'''
with tempfile.TemporaryDirectory(prefix='zyren-cloud-media-') as temp:
 p=Path(temp);(p/'main.cpp').write_text(code)
 subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True)
 values=json.loads(subprocess.check_output([str(p/'run')],text=True))
output=root/'packages/zyren_geospatial/test/fixtures/clouds/media.json'
output.write_text(json.dumps({'revision':inventory['revision'],'sourceFiles':loaded,'samples':values},indent=2)+'\n')
print(f'{len(values)} source media samples')

shadow=original('shadow.frag')
shadow=shadow[shadow.index('vec4 marchClouds('):shadow.index('void getRayNearFar(')]
shadowCode=baseCode.replace('#define SHAPE_DETAIL','#define SHADOW').replace('#define TURBULENCE','').replace('vec3 minIntervalHeights=', 'vec4 shadowLayerMask=V4(1,1,0,0);\nvec3 minIntervalHeights=')
shadowCode+='\nint maxIterationCount=25;float minStepSize=100,maxStepSize=1000,opticalDepthTailScale=2,minDensity=.0001f,minExtinction=.0001f,minTransmittance=.01f,bottomRadius=6360000;\n'
shadowCode+=translate(shadow)
shadowCode+=r"""
int main(){std::cout<<std::setprecision(9)<<"[";weatherValue=V4(1);shapeValue=1;detailValue=0;turbulenceValue=V3(.5f);coverage=.6f;
for(int i=0;i<16;i++){
 vec3 origin=V3(0,0,6362200);vec3 direction=normalize(V3((i%4)*.2f,0,-1));float distance=1400+(i/4)*100.f,jitter=(i%7)/7.f,mip=(i%4)*.5f;
 vec4 value=marchClouds(origin,direction,distance,jitter,mip);
 if(i)std::cout<<',';std::cout<<"{\"origin\":["<<origin.x<<','<<origin.y<<','<<origin.z<<"],\"direction\":["<<direction.x<<','<<direction.y<<','<<direction.z<<"],\"distance\":"<<distance<<",\"jitter\":"<<jitter<<",\"mip\":"<<mip<<",\"expected\":["<<value.x<<','<<value.y<<','<<value.z<<','<<value.w<<"]}";
}std::cout<<"]";}
"""
with tempfile.TemporaryDirectory(prefix='zyren-shadow-media-') as temp:
 p=Path(temp);(p/'main.cpp').write_text(shadowCode)
 subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True)
 values=json.loads(subprocess.check_output([str(p/'run')],text=True))
output=root/'packages/zyren_geospatial/test/fixtures/clouds/shadow.json'
output.write_text(json.dumps({'revision':inventory['revision'],'sourceFiles':loaded,'samples':values},indent=2)+'\n')
print(f'{len(values)} source shadow rays')

primary=original('clouds.frag')
primary=primary[primary.index('float marchOpticalDepth('):primary.index('#ifdef SHADOW_LENGTH\n\nfloat marchShadowLength(')]
# Lower the source's eight-octave preprocessor loop for this scalar host.
primary=primary.replace('i < 12','i < 8')
primaryCode=baseCode.replace('#define SHAPE_DETAIL','').replace('#define TURBULENCE','')+r'''
#define POWDER
#define MULTI_SCATTERING_OCTAVES 8
#define UNROLLED_LOOP_INDEX 0
#define METER_TO_LENGTH_UNIT .001f
float remapClamped(float x,float a,float b){return saturate((x-a)/(b-a));}
vec3 mix(vec3 a,vec3 b,float t){return a*(1-t)+b*t;}
vec3 sunDirection=V3(0,0,1);
int maxIterationCount=200,maxIterationCountToSun=1,maxIterationCountToGround=0;
float minStepSize=100,maxStepSize=1000,maxRayDistance=100000,perspectiveStepScale=1.01f,minDensity=.0001f,minExtinction=.0001f,minTransmittance=.1f;
float minSecondaryStepSize=100,secondaryStepScale=2,bottomRadius=6360000,minHeight=750,maxHeight=8000,shadowTopHeight=2200;
float skyLightScale=1,groundBounceScale=1,powderScale=.8f,powderExponent=150,maxShadowFilterRadius=6;
GroundIrradiance vGroundIrradiance={V3(1,.9f,.8f),V3(.2f,.3f,.4f)};
CloudsIrradiance vCloudsIrradiance={V3(1,.9f,.8f),V3(.2f,.3f,.4f),V3(1,.9f,.8f),V3(.2f,.3f,.4f)};
float sampleShadowOpticalDepth(vec3 p,float d,float r,float jitter){return 0;}
'''+translate(primary)
primaryCode+=r'''
int main(){std::cout<<std::setprecision(9)<<"[";weatherValue=V4(1);shapeValue=1;detailValue=0;turbulenceValue=V3(.5f);coverage=.6f;
for(int i=0;i<24;i++){
 vec3 origin=V3(0,0,6360750);vec3 direction=normalize(V3((i%4)*.2f,0,1));vec2 range=V2((i/8)*100.f,2000+(i/8)*100.f);float jitter=(i%7)/7.f,texels=pow(2.f,(i%4)*.5f),depth;ivec3 count={0,0,0};
 vec4 value=marchClouds(origin,direction,range,dot(direction,sunDirection),jitter,texels,depth,count);
 if(i)std::cout<<',';std::cout<<"{\"origin\":["<<origin.x<<','<<origin.y<<','<<origin.z<<"],\"direction\":["<<direction.x<<','<<direction.y<<','<<direction.z<<"],\"range\":["<<range.x<<','<<range.y<<"],\"jitter\":"<<jitter<<",\"texels\":"<<texels<<",\"expected\":["<<value.x<<','<<value.y<<','<<value.z<<','<<value.w<<','<<depth<<"]}";
}std::cout<<"]";}
'''
for preset in ['low','medium']:
 selected=primaryCode
 if preset=='medium':
  selected='#define SHAPE_DETAIL\n'+selected.replace('#define POWDER','#define POWDER\n#define GROUND_BOUNCE')
  selected=selected.replace('maxIterationCount=200,maxIterationCountToSun=1,maxIterationCountToGround=0','maxIterationCount=500,maxIterationCountToSun=2,maxIterationCountToGround=1').replace('minStepSize=100,maxStepSize=1000,maxRayDistance=100000','minStepSize=50,maxStepSize=1000,maxRayDistance=200000').replace('minTransmittance=.1f','minTransmittance=.01f')
 with tempfile.TemporaryDirectory(prefix='zyren-cloud-march-') as temp:
  p=Path(temp);(p/'main.cpp').write_text(selected)
  subprocess.run(['clang++','-O2','-std=c++17','-ffp-contract=off',str(p/'main.cpp'),'-o',str(p/'run')],check=True)
  values=json.loads(subprocess.check_output([str(p/'run')],text=True))
 name='march' if preset=='low' else 'march_'+preset
 output=root/('packages/zyren_geospatial/test/fixtures/clouds/'+name+'.json')
 output.write_text(json.dumps({'revision':inventory['revision'],'sourceFiles':loaded,'lighting':f'Constant sun [1,.9,.8] and sky [.2,.3,.4]; no Beer-map optical depth; source {preset} preset','samples':values},indent=2)+'\n')
 print(f'{len(values)} source {preset} cloud rays')
