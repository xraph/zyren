import 'package:zyren/zyren.dart';

/// Three r184 RGB dithering in linear color, after grading and antialiasing.
/// The noise is fixed to the viewport, so stationary scenes do not shimmer.
final class DitheringEffect {
  final GpuScope _scope;
  final ScreenEffect effect;
  DitheringEffect._(this._scope, this.effect);
  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();
  static Future<DitheringEffect> create(GpuScope owner) async {
    final scope = owner.createChild(label: 'display dithering');
    try {
      final shader = await scope.shaders.compile(
        ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
fn decode(c:vec3<f32>)->vec3<f32>{return select(pow((c+.055)/1.055,vec3<f32>(2.4)),c/12.92,c<=vec3<f32>(.04045));}
fn encode(c:vec3<f32>)->vec3<f32>{return select(1.055*pow(c,vec3<f32>(1./2.4))-.055,c*12.92,c<=vec3<f32>(.0031308));}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let c=textureLoad(sceneColor,vec2<i32>(v.position.xy),0);
 let color=decode(clamp(c.rgb/max(c.a,1e-6),vec3<f32>(0.),vec3<f32>(1.)));
 let pixel=vec2<f32>(v.position.x,screen.viewport.y-v.position.y);
 let dt=dot(pixel,vec2<f32>(12.9898,78.233));
 let sn=dt-floor(dt/3.141592653589793)*3.141592653589793;
 let grid=fract(sin(sn)*43758.5453);
 let shift=vec3<f32>(.25,-.25,.25)/255.;
 return vec4<f32>(encode(clamp(color+mix(2.*shift,-2.*shift,grid),vec3<f32>(0.),vec3<f32>(1.)))*c.a,c.a);
}
''', label: 'source RGB dither'),
      );
      return DitheringEffect._(
        scope,
        await scope.materials.compileEffect(
          PostProcessDescriptor(
            program: shader,
            stage: PostProcessStage.display,
          ),
        ),
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}
