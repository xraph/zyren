import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

class ColorExtension extends GeospatialExtension {
  @override
  final String localId;
  final bool rotate;
  ColorExtension(this.localId, {this.rotate = false});
  @override
  Future<void> attachGeospatial(GeospatialContext context) async {
    final program = await context.sceneContext.shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var image: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
 let p = array<vec2<f32>,3>(vec2<f32>(-1.0,-1.0),vec2<f32>(3.0,-1.0),vec2<f32>(-1.0,3.0));
 return vec4<f32>(p[i],0.0,1.0);
}
@fragment fn fragment(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
 let c = textureLoad(image,vec2<i32>(p.xy),0);
 return ${rotate ? 'vec4<f32>(c.b,c.r,c.g,c.a)' : 'vec4<f32>(c.rgb + vec3<f32>(1.0,0.0,0.0),c.a)'};
}
'''),
    );
    context.visuals.addEffect(
      context.sceneContext,
      GeoVisualPass(name: localId, owner: id, after: rotate ? {'red'} : {}),
      build: (frame) async {
        final output = await frame.createColorTexture();
        return GraphEffect(
          output: output,
          passes: [
            RenderPassDescriptor(
              name: '$localId.pass',
              program: program,
              color: ColorAttachment(output),
              bindings: ShaderBindings([
                TextureBinding.sampled(0, frame.input),
              ]),
              reads: [frame.input],
              writes: [output],
            ),
          ],
        );
      },
    );
  }
}

void main() {
  test(
    'visual contributions execute in the native shared graph and retire owned resources',
    () async {
      final backend = await NativeBackend.create();
      final geo = GeospatialPlugin(
        extensions: [
          ColorExtension('rotate', rotate: true),
          ColorExtension('red'),
        ],
      );
      final engine = await SceneEngine.create(
        scene: Scene()..background = const Color3(0, 0, 0),
        camera: PerspectiveCamera(),
        plugins: geo.scenePlugins,
        backendFactory: () async => backend.createView(),
      );
      try {
        for (final size in [(96, 64), (40, 96)]) {
          final frame = await engine.render(
            elapsed: Duration.zero,
            width: size.$1,
            height: size.$2,
          );
          final i = (size.$1 * (size.$2 ~/ 2) + size.$1 ~/ 2) * 4;
          expect(frame.pixels[i], lessThan(3));
          expect(frame.pixels[i + 1], greaterThan(250));
          expect(frame.pixels[i + 2], lessThan(3));
        }
        expect(geo.visuals.passes, hasLength(2));
      } finally {
        await engine.dispose();
        expect(geo.visuals.passes, isEmpty);
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}
