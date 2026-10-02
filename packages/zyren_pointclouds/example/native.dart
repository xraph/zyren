import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';

/// Run with `fvm dart run packages/zyren_pointclouds/example/native.dart`.
Future<void> main(List<String> args) async {
  final data = await const XyzPointCloudLoader(sourceVersion: 'fixture-1')
      .parse(
        Uint8List.fromList(ascii.encode('-0.5 0 0\n0 0.5 0\n0.5 0 0')),
        sourceUri: Uri.parse('memory:point-example'),
      );
  final cloud = ScenePointCloud(
    data: data,
    material: PointsMaterial(size: 12, color: const Color3(.1, .7, 1)),
  );
  final scene = Scene()..background = const Color3(0, 0, 0);
  scene.add(cloud.object);
  final backend = await NativeBackend.create();
  try {
    final frame =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: OrthographicCamera(),
                size: PhysicalSize(256, 256),
              ),
            )
            as ReadbackOutput;
    final output = args.isEmpty ? 'pointcloud.ppm' : args.single;
    File(output).writeAsBytesSync([
      ...ascii.encode('P6\n256 256\n255\n'),
      for (var i = 0; i < frame.image.pixels.length; i += 4)
        ...frame.image.pixels.sublist(i, i + 3),
    ]);
    final hit = cloud.pick(
      Ray(const Vec3(.5, 0, 5), const Vec3(0, 0, -1)),
      radius: .01,
    )!;
    print(
      '${backend.capabilities.backend}: saved $output; picked ${hit.identity}.',
    );
  } finally {
    cloud.close();
    await backend.close();
  }
}
