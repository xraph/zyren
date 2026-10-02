import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_capture/native_capture.dart';

Future<void> main(List<String> args) async {
  final parent = Directory(
    args.isEmpty ? Directory.systemTemp.path : args.first,
  );
  final scene = Scene()..background = const Color3(.025, .04, .065);
  scene.add(
    Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(.9, .25, .1))),
  );
  scene.add(
    Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(.1, .7, .8)))
      ..position = const Vec3(1, .6, 0)
      ..scale = const Vec3(.5, 1.4, .5),
  );
  final capture = nativeCapture(
    scene: scene,
    sceneId: 'capture-fixture',
    documentId: 'fixture-v1',
    outputParent: parent,
  );
  try {
    final plan = CapturePlan(size: PhysicalSize(64, 64), frameCount: 4);
    final first = await capture.start(id: 'orbit-a', plan: plan).done;
    final second = await capture.start(id: 'orbit-b', plan: plan).done;
    for (var i = 0; i < first.frames.length; i++) {
      final a = await File(first.frames[i]).readAsBytes(),
          b = await File(second.frames[i]).readAsBytes();
      if (a.length != b.length ||
          List.generate(a.length, (j) => j).any((j) => a[j] != b[j])) {
        throw StateError('Native repeatability check failed at frame $i.');
      }
    }
    print('Four native PNG frames repeated byte-for-byte.');
    print(first.manifest);
    print(second.manifest);
  } finally {
    await capture.close();
  }
}
