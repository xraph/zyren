import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main() async {
  final backend = await NativeBackend.create();
  try {
    final compiler = backend.createShaderCompiler(label: 'weather effects');
    final program = await compiler.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var output: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  if (any(id.xy >= textureDimensions(output))) { return; }
  textureStore(output, vec2<i32>(id.xy), vec4<f32>(1.0, 0.0, 0.0, 1.0));
}
''', label: 'heatmap.wgsl'),
    );
    final entry = program.entryPoints.single;
    print(
      '${program.source.label}: ${entry.stage.name} ${entry.name}, '
      'workgroup size ${entry.workgroupSize}',
    );
    try {
      await compiler.compile(
        ShaderSource.wgsl(
          '@compute @workgroup_size(1) fn main() { let value: f32 = true; }',
          label: 'invalid.wgsl',
        ),
      );
    } on ShaderCompilationException catch (error) {
      final location = error.diagnostics.first.location;
      print(
        '${error.source.label}:${location?.line}:${location?.column}: ${error.code.name}',
      );
    }
    await compiler.close();
    final stats = await backend.shaderStats();
    print(
      'After close: ${stats.livePrograms} programs, ${stats.cachedModules} cached modules.',
    );
    print(
      'Module validation only. Render graph execution is still in progress.',
    );
  } finally {
    await backend.close();
  }
}
