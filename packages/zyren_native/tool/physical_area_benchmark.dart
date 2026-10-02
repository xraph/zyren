import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main(List<String> args) async {
  const warmupFrames = 120, measuredFrames = 120;
  final output = args.isEmpty ? '/tmp/zyren-area-profile' : args.single;
  final directory = Directory(output)..createSync(recursive: true);
  final backend = await NativeBackend.create();
  final rows = <Map<String, Object?>>[];
  try {
    final scene = Scene()..background = const Color3(0, 0, 0);
    final plane = PlaneGeometry(width: 4, height: 3);
    final geometry = BufferGeometry.fromAttributes(
      attributes: {
        ...plane.attributes,
        VertexSemantic.tangent: VertexAttribute(
          Float32List.fromList([
            for (var i = 0; i < plane.vertexCount; i++) ...[1, 0, 0, 1],
          ]),
          format: VertexFormat.float32x4,
        ),
      },
      indices: plane.indices,
    );
    final mesh = scene.add(Mesh(geometry, PhysicalMaterial()));
    scene.add(
      RectAreaLight(width: 4, height: 1.3, intensity: 2)
        ..position = const Vec3(.4, -.3, 2),
    );
    final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
    for (final kind in ['isotropic', 'anisotropic', 'film', 'combined']) {
      mesh.material = PhysicalMaterial(
        baseColor: const Color3(.6, .2, .05),
        roughness: .35,
        anisotropy: kind == 'anisotropic' || kind == 'combined' ? .7 : 0,
        iridescence: kind == 'film' || kind == 'combined' ? .8 : 0,
        iridescenceThicknessMaximum: 350,
        clearcoat: .4,
        clearcoatRoughness: .2,
        sheenColor: const Color3(.1, .02, .01),
        sheenRoughness: .4,
      );
      final times = <int>[], gpu = <int?>[];
      String source = 'unavailable';
      for (var i = 0; i < warmupFrames + measuredFrames; i++) {
        final timer = Stopwatch()..start();
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(512, 384),
                  ),
                )
                as ReadbackOutput;
        timer.stop();
        final inspection = await backend.inspectGpu();
        source = inspection.gpuTimeSource;
        if (i >= warmupFrames) {
          times.add(timer.elapsedMicroseconds);
          gpu.add(inspection.lastSubmissionGpuTimeNs);
        }
        if (i == warmupFrames + measuredFrames - 1) {
          File(
            '${directory.path}/$kind.rgba',
          ).writeAsBytesSync(output.image.pixels);
        }
      }
      rows.add({
        'material': kind,
        'gpuTimeNs': gpu,
        'gpuTimeSource': source,
        'endToEndReadbackMicros': times,
      });
    }
    final result = {
      'backend': backend.capabilities.backend,
      'adapter': backend.capabilities.adapterName,
      'os': Platform.operatingSystemVersion,
      'size': [512, 384],
      'warmupFrames': warmupFrames,
      'measuredFrames': measuredFrames,
      'profiles': rows,
    };
    final json = const JsonEncoder.withIndent('  ').convert(result);
    File('${directory.path}/profile.json').writeAsStringSync(json);
    stdout.writeln(json);
  } finally {
    await backend.close();
  }
}
