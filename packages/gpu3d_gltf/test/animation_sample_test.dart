import 'dart:io';
import 'dart:isolate';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'model_test.dart' show load;

void main() {
  test(
    'Khronos BoxAnimated holds its shorter rotation channel until clip end',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:gpu3d_gltf/gpu3d_gltf.dart'),
      );
      final model = await load(
        await File.fromUri(
          library!.resolve('../../../test_assets/gltf/khronos/BoxAnimated.glb'),
        ).readAsBytes(),
      );
      final a = model.instantiate(), b = model.instantiate();
      final clip = a.animations.single;
      final rotation = clip.tracks.whereType<QuaternionKeyframeTrack>().single;
      final translation = clip.tracks.whereType<VectorKeyframeTrack>().single;
      expect(rotation.times.last, 2.5);
      expect(translation.times.last, closeTo(3.70833, 1e-5));
      expect(clip.durationSeconds, translation.times.last);
      final action = a.mixer.play(clip)..pause();
      b.mixer.play(b.animations.single).pause();
      final still = b.mixer.nodes[translation.target]!.position;
      action.seek(const Duration(milliseconds: 2700));
      final first = a.mixer.nodes[translation.target]!.position;
      final held = a.mixer.nodes[rotation.target]!.quaternion;
      action.seek(const Duration(milliseconds: 3500));
      expect(a.mixer.nodes[rotation.target]!.quaternion, held);
      expect(a.mixer.nodes[translation.target]!.position, isNot(first));
      expect(b.mixer.nodes[translation.target]!.position, still);
      action.seek(Duration.zero);
      action.resume();
      a.mixer.update(const Duration(seconds: 4));
      expect(action.timeSeconds, closeTo(4 - clip.durationSeconds, 1e-9));
      expect(
        a.mixer.nodes[translation.target]!.position,
        translation.sample(action.timeSeconds),
      );
    },
  );
}
