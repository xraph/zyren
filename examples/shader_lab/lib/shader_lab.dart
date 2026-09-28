import 'dart:typed_data';
import 'package:zyren/zyren.dart';

const shaderLabControls = ServiceKey<ShaderLabControls>('shader-lab.controls');

/// Parameters stay in a uniform buffer. Updating gain does not rebuild pipelines.
class ShaderLabControls {
  final Future<void> Function(double) _setGain;
  ShaderLabControls._(this._setGain);
  Future<void> setGain(double value) {
    if (!value.isFinite || value < 0 || value > 16) {
      throw ArgumentError.value(value, 'gain');
    }
    return _setGain(value);
  }
}

/// Two public effect registrations: HDR gain followed by a small spatial glow.
class ShaderLabPlugin extends ScenePlugin {
  @override
  String get id => 'shader-lab';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.postprocessing,
    RenderFeature.hdr,
    RenderFeature.shaderMaterials,
    RenderFeature.scopedResources,
  };
  @override
  Future<void> attach(PluginContext context) async {
    final parameters = await context.resources.createBuffer(
      BufferDescriptor(
        size: 16,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    Future<void> setGain(double gain) async {
      await context.resources.writeBuffer(
        parameters,
        Float32List.fromList([gain, 0, 0, 0]),
      );
      context.invalidate();
    }

    await setGain(1.5);
    final gain = await context.shaders.compile(
      ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@group(1) @binding(0) var<uniform> parameters: vec4<f32>;
@fragment fn fragment(v: ScreenVertex) -> @location(0) vec4<f32> {
  let color = textureLoad(sceneColor, vec2<i32>(v.position.xy), 0);
  return vec4<f32>(color.rgb * parameters.x, color.a);
}
'''),
    );
    final glow = await context.shaders.compile(
      ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@fragment fn fragment(v: ScreenVertex) -> @location(0) vec4<f32> {
  let p = vec2<i32>(v.position.xy);
  let maximum = vec2<i32>(textureDimensions(sceneColor)) - vec2<i32>(1);
  var sum = vec3<f32>(0.);
  for (var y = -2; y <= 2; y++) {
    for (var x = -2; x <= 2; x++) {
      let c = textureLoad(sceneColor, clamp(p + vec2<i32>(x,y), vec2<i32>(0), maximum), 0);
      sum += max(c.rgb - vec3<f32>(1.), vec3<f32>(0.));
    }
  }
  let original = textureLoad(sceneColor, p, 0);
  return vec4<f32>(original.rgb + sum * .02, original.a);
}
'''),
    );
    for (final descriptor in [
      PostProcessDescriptor(
        program: gain,
        label: 'gain',
        bindings: ShaderBindings([
          BufferBinding.uniform(0, parameters, group: 1),
        ]),
      ),
      PostProcessDescriptor(program: glow, label: 'glow'),
    ]) {
      final effect = await context.materials.compileEffect(descriptor);
      context.scope.keep(context.scene.addEffect(effect));
    }
    context.provide(shaderLabControls, ShaderLabControls._(setGain));
  }
}
