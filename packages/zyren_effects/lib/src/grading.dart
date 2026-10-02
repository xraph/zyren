import 'package:zyren/zyren.dart';
import 'hald.dart';

/// Immutable grading resources. Register [effect] on a scene, then dispose its
/// registration before closing this owner. Build a candidate before replacing it.
final class ColorGradingEffect {
  final GpuScope _scope;
  final ScreenEffect effect;
  ColorGradingEffect._(this._scope, this.effect);
  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();

  static Future<ColorGradingEffect> create(
    GpuScope owner, {
    required HaldLookup lut,
    HaldInterpolation interpolation = HaldInterpolation.trilinear,
    double intensity = 1,
  }) async {
    if (!intensity.isFinite || intensity < 0 || intensity > 1) {
      throw ArgumentError.value(intensity, 'intensity');
    }
    final scope = owner.createChild(label: 'Hald color grading');
    try {
      final texture = await scope.resources.createTexture(
        TextureDescriptor(
          width: lut.size,
          height: lut.size,
          depth: lut.size,
          dimension: TextureDimension.d3,
          format: TextureFormat.rgba8Unorm,
          usage: {TextureUsage.sampled, TextureUsage.copyDestination},
        ),
      );
      await scope.resources.writeTexture(texture, lut.bytes);
      final program = await scope.shaders.compile(
        ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
$_lookupWgsl
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
 let c=textureLoad(sceneColor,vec2<i32>(v.position.xy),0);
 let color=clamp(c.rgb/max(c.a,1e-6),vec3<f32>(0.),vec3<f32>(1.));
 let p=color*f32(textureDimensions(lookup).x-1u);
 let graded=${interpolation == HaldInterpolation.trilinear ? 'trilinear' : 'tetrahedral'}(p);
 return vec4<f32>(mix(color,graded,${intensity.toString()})*c.a,c.a);
}
''', label: 'Hald lookup'),
      );
      final effect = await scope.materials.compileEffect(
        PostProcessDescriptor(
          program: program,
          stage: PostProcessStage.display,
          bindings: ShaderBindings([
            TextureBinding.sampled(0, texture, group: 1),
          ]),
        ),
      );
      return ColorGradingEffect._(scope, effect);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}

const _lookupWgsl = '''
@group(1) @binding(0) var lookup:texture_3d<f32>;
fn voxel(p:vec3<i32>)->vec3<f32> {
 return textureLoad(lookup,clamp(p,vec3<i32>(0),vec3<i32>(textureDimensions(lookup))-1),0).rgb;
}
fn trilinear(p:vec3<f32>)->vec3<f32> {
 let b=vec3<i32>(floor(p));let f=fract(p);
 return mix(mix(mix(voxel(b),voxel(b+vec3<i32>(1,0,0)),f.x),mix(voxel(b+vec3<i32>(0,1,0)),voxel(b+vec3<i32>(1,1,0)),f.x),f.y),
 mix(mix(voxel(b+vec3<i32>(0,0,1)),voxel(b+vec3<i32>(1,0,1)),f.x),mix(voxel(b+vec3<i32>(0,1,1)),voxel(b+vec3<i32>(1)),f.x),f.y),f.z);
}
fn tetrahedral(p:vec3<f32>)->vec3<f32> {
 let b=vec3<i32>(floor(p));let f=fract(p);
 var v2=vec3<i32>(0);var v3=vec3<i32>(0);var frac=vec3<f32>(0.);
 if(f.r>=f.g){
  if(f.g>f.b){frac=f.rgb;v2=vec3<i32>(1,0,0);v3=vec3<i32>(1,1,0);}
  else if(f.r>=f.b){frac=f.rbg;v2=vec3<i32>(1,0,0);v3=vec3<i32>(1,0,1);}
  else{frac=f.brg;v2=vec3<i32>(0,0,1);v3=vec3<i32>(1,0,1);}
 }else{
  if(f.b>f.g){frac=f.bgr;v2=vec3<i32>(0,0,1);v3=vec3<i32>(0,1,1);}
  else if(f.r>=f.b){frac=f.grb;v2=vec3<i32>(0,1,0);v3=vec3<i32>(1,1,0);}
  else{frac=f.gbr;v2=vec3<i32>(0,1,0);v3=vec3<i32>(0,1,1);}
 }
 return voxel(b)*(1.-frac.x)+voxel(b+v2)*(frac.x-frac.y)+voxel(b+v3)*(frac.y-frac.z)+voxel(b+vec3<i32>(1))*frac.z;
}
''';
