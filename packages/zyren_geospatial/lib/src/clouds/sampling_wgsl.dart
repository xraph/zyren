import 'package:zyren/zyren.dart';
import 'textures.dart';

Set<String> _filteredMaps(CloudTextures maps) => {
  for (final (name, texture) in [
    ('cloudWeatherMap', maps.weather),
    ('cloudTurbulenceMap', maps.turbulence),
  ])
    if ((texture.descriptor as TextureDescriptor).format.filterable) name,
};

List<ShaderBinding> cloudSamplingBindings(CloudTextures maps) => [
  if (_filteredMaps(maps).isNotEmpty)
    SamplerBinding(
      9,
      group: 2,
      sampler: const SamplerDescriptor(
        wrapU: TextureWrap.repeat,
        wrapV: TextureWrap.repeat,
      ),
    ),
];

String cloudSamplingShader(CloudTextures maps) =>
    _samplingWgsl(_filteredMaps(maps));

// Float volumes retain explicit filtering because R32Float is unfilterable.
final cloudSamplingWgsl = _samplingWgsl({});

String _samplingWgsl(Set<String> filtered) =>
    [
      if (filtered.isNotEmpty)
        '@group(2) @binding(9) var cloudRepeatSampler:sampler;',
      for (final (name, slot, volume) in [
        ('cloudWeatherMap', 1, false),
        ('cloudShapeMap', 2, true),
        ('cloudDetailMap', 3, true),
        ('cloudTurbulenceMap', 4, false),
      ])
        if (filtered.contains(name))
          '''
@group(2) @binding($slot) var $name:texture_2d<f32>;
fn sample_$name(uv:vec2<f32>,mip:f32)->vec4<f32>{
 return textureSampleLevel($name,cloudRepeatSampler,uv,mip);
}
'''
        else
          '''
@group(2) @binding($slot) var $name:texture_${volume ? '3d' : '2d'}<f32>;
fn ${name}Level(uv:vec${volume ? 3 : 2}<f32>,level:i32)->vec4<f32>{
 let size=vec${volume ? 3 : 2}<i32>(textureDimensions($name,level));let p=fract(uv)*vec${volume ? 3 : 2}<f32>(size)-.5;
 let i=vec${volume ? 3 : 2}<i32>(floor(p));let f=fract(p);var value=vec4<f32>(0.);
 ${volume ? 'for(var z=0;z<2;z++){' : ''}
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){
  let q=((i+vec${volume ? 3 : 2}<i32>(x,y${volume ? ',z' : ''}))%size+size)%size;
  value+=textureLoad($name,q,level)*select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1)${volume ? '*select(1.-f.z,f.z,z==1)' : ''};
 }}${volume ? '}' : ''}return value;
}
fn sample_$name(uv:vec${volume ? 3 : 2}<f32>,mip:f32)->vec4<f32>{
 let level=clamp(mip,0.,f32(textureNumLevels($name)-1u));let lo=i32(floor(level));let hi=min(lo+1,i32(textureNumLevels($name))-1);
 let lower=${name}Level(uv,lo);
 if(hi==lo || fract(level)==0.){return lower;}
 return mix(lower,${name}Level(uv,hi),fract(level));
}
''',
    ].join() +
    r'''
fn cloudSampleWeather(position:vec3<f32>,height:f32,mip:f32,shadow:bool)->CloudWeather{
 let uv=cloudGlobeUv(position);return cloudWeather(sample_cloudWeatherMap(uv*cloud.v[15].xy+cloud.v[15].zw,mip),height,shadow);
}
fn cloudSampleMedium(weather:CloudWeather,position:vec3<f32>,mip:f32,jitter:f32)->CloudMedium{
 let uv=cloudGlobeUv(position);
 let evolution=-normalize(position)*length(cloud.v[15].zw)*2e4;
 var turbulence=vec3<f32>(0.);
 if(CLOUD_TURBULENCE){
  turbulence=cloud.v[19].w*(sample_cloudTurbulenceMap(uv*cloud.v[15].xy*cloud.v[20].xy,0.).rgb*2.-1.)*
   dot(weather.density,cloudRemap4(weather.height,vec4<f32>(.3),vec4<f32>(0.)));
 }
 let shape=sample_cloudShapeMap((position+evolution+turbulence)*cloud.v[16].xyz+cloud.v[17].xyz,0.).r;
 var detail=0.;
 if(CLOUD_DETAIL && mip*.5+(jitter-.5)*.5<.5){detail=sample_cloudDetailMap((position+turbulence)*cloud.v[18].xyz+cloud.v[19].xyz,0.).r;}
 return cloudMedium(weather,shape,detail,mip,jitter);
}
''';
