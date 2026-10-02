String blurShader(
  String mode,
  List<double> weights,
  List<double> offsets,
  double blend,
) {
  String pair(int i) =>
      'color+=(sample(uv+delta*${offsets[i]})+sample(uv-delta*${offsets[i]}))*${weights[i]};';
  final body = switch (mode) {
    'horizontal' || 'vertical' =>
      '''let delta=vec2<f32>(${mode == 'horizontal' ? '1.,0.' : '0.,1.'})*texel;
var color=sample(uv)*${weights[0]};
${[for (var i = 1; i < weights.length; i++) pair(i)].join('\n')}
return color;''',
    'kawaseDown' => 'return sample(uv)*.5+diagonal(uv,texel*.5)*.125;',
    'kawaseUp' => 'return diagonal(uv,texel*.5)/12.+axes(uv,texel*.5)/6.;',
    'mipmapDown' =>
      'return (sample(uv)+diagonal(uv,texel))*.125+axes(uv,texel*2.)*.0625+diagonal(uv,texel*2.)*.03125;',
    'mipmapUp' => 'return tent(uv,texel);',
    'surfaceDown' =>
      '''var color=sample(uv)/18.;
for(var y=-1;y<=1;y+=2){for(var x=-1;x<=1;x+=2){
 let d=vec2<f32>(f32(x),f32(y))*texel;
 color+=border(uv+d)*.125+border(uv+d*2.)/18.;
}}
color+=(border(uv+vec2<f32>(texel.x*2.,0.))+border(uv-vec2<f32>(texel.x*2.,0.))+border(uv+vec2<f32>(0.,texel.y*2.))+border(uv-vec2<f32>(0.,texel.y*2.)))/18.;
return color;''',
    'surfaceUp' => 'return mix(sampleHigh(uv),tent(uv,texel),$blend);',
    _ => throw ArgumentError.value(mode, 'mode'),
  };
  return '''
@group(0) @binding(0) var inputImage:texture_2d<f32>;
@group(0) @binding(2) var outputImage:texture_storage_2d<rgba16float,write>;
${_sample('inputImage', 'sample')}
${mode == 'surfaceUp' ? '@group(0) @binding(1) var highImage:texture_2d<f32>;${_sample('highImage', 'sampleHigh')}' : ''}
fn diagonal(uv:vec2<f32>,d:vec2<f32>)->vec4<f32>{return sample(uv+d)+sample(uv-d)+sample(uv+vec2<f32>(d.x,-d.y))+sample(uv+vec2<f32>(-d.x,d.y));}
fn axes(uv:vec2<f32>,d:vec2<f32>)->vec4<f32>{return sample(uv+vec2<f32>(d.x,0.))+sample(uv-vec2<f32>(d.x,0.))+sample(uv+vec2<f32>(0.,d.y))+sample(uv-vec2<f32>(0.,d.y));}
fn border(uv:vec2<f32>)->vec4<f32>{return select(vec4<f32>(0.),sample(uv),all(uv>=vec2<f32>(0.))&&all(uv<=vec2<f32>(1.)));}
fn tent(uv:vec2<f32>,d:vec2<f32>)->vec4<f32>{return sample(uv)*.25+axes(uv,d)*.125+diagonal(uv,d)*.0625;}
fn blurPixel(uv:vec2<f32>)->vec4<f32>{let texel=1./vec2<f32>(textureDimensions(inputImage));$body}
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let size=textureDimensions(outputImage);if(any(id.xy>=size)){return;}
 let uv=(vec2<f32>(id.xy)+.5)/vec2<f32>(size);
 textureStore(outputImage,vec2<i32>(id.xy),blurPixel(uv));
}
''';
}

String _sample(String texture, String name) =>
    '''
fn ${name}Load(p:vec2<i32>)->vec4<f32>{return textureLoad($texture,clamp(p,vec2<i32>(0),vec2<i32>(textureDimensions($texture))-1),0);}
fn $name(uv:vec2<f32>)->vec4<f32>{
 let p=uv*vec2<f32>(textureDimensions($texture))-.5;let b=vec2<i32>(floor(p));let f=fract(p);
 return mix(mix(${name}Load(b),${name}Load(b+vec2<i32>(1,0)),f.x),mix(${name}Load(b+vec2<i32>(0,1)),${name}Load(b+vec2<i32>(1)),f.x),f.y);
}
''';
