import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'model_test.dart' show load;
import 'support/animated_fixture.dart';

void main() {
  test(
    'prepared poses and core mixers share native bindings and imported events',
    () async {
      final asset = await load(animatedModel());
      final instance = asset.instantiate(), other = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as ModelSkinnedMesh;
      final otherMesh = other.nodes[0]!.children.single as ModelSkinnedMesh;
      expect(mesh.geometry, same(otherMesh.geometry));
      expect(instance.animations.single, isA<AnimationClip>());
      expect(instance.animations.single.events.map((e) => e.id), [
        'start',
        'middle',
        'end',
      ]);
      final edit = instance.preparePose(
        animation: asset.animations.single,
        time: const Duration(milliseconds: 500),
      );
      expect(mesh.morphWeights.single, 0);
      expect(instance.nodes[1]!.position.x, 0);
      edit();
      expect(mesh.morphWeights.single, .5);
      expect(instance.nodes[1]!.position.x, 2);
      expect(otherMesh.morphWeights.single, 0);
      expect(other.nodes[1]!.position.x, 0);
      instance.mixer
          .play(instance.animations.single)
          .seek(const Duration(seconds: 1));
      expect(mesh.morphWeights.single, 1);
      expect(instance.nodes[1]!.position.x, 4);
      expect(mesh.geometry.positions.first, -1);
    },
  );

  test(
    'invalid native poses preserve weights and reject changed hierarchy',
    () async {
      final asset = await load(animatedModel()), instance = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as ModelSkinnedMesh;
      expect(
        () => instance.preparePose(
          animation: asset.animations.single,
          time: const Duration(seconds: 1),
          morphWeights: {
            0: [double.nan],
          },
        ),
        throwsArgumentError,
      );
      expect(mesh.morphWeights.single, 0);
      expect(instance.nodes[1]!.position.x, 0);
      instance.nodes[0]!.add(instance.nodes[1]!);
      expect(() => instance.preparePose(), throwsStateError);
    },
  );
}
