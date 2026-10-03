import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren/zyren.dart';

Scene texturedScene(int count, {int edge = 16}) {
  final scene = Scene();
  for (var i = 0; i < count; i++) {
    scene.add(
      Mesh(
        PlaneGeometry(),
        UnlitMaterial(
          colorMap: TextureMap(
            image: TextureImage.rgba(
              width: edge,
              height: edge,
              pixels: Uint8List(edge * edge * 4),
            ),
          ),
        ),
      ),
    );
  }
  return scene;
}

void main() {
  final camera = PerspectiveCamera();
  FrameSubmission capture(Scene scene) => FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(16, 16),
  );

  test(
    'small upload target spreads a burst while the old cover follows the camera',
    () {
      final encoder = ScenePacketEncoder(viewId: 1, uploadBudgetBytes: 1500);
      final old = Scene()..add(Mesh(PlaneGeometry(), UnlitMaterial()));
      final initial = encoder.encode(capture(old));
      encoder.accept(initial);
      final candidate = texturedScene(3);
      var packets = 0;
      for (; packets < 8; packets++) {
        camera.position = Vec3(packets.toDouble() * .01, 0, 5);
        final packet = encoder.encode(capture(candidate));
        expect(packet.uploadedBytes, lessThanOrEqualTo(1500));
        expect(packet.submission.camera.origin, camera.position.storage);
        if (!packet.ready) {
          expect(packet.presentedIdentities, initial.presentedIdentities);
        }
        encoder.accept(packet);
        if (packet.ready) break;
      }
      expect(packets, inInclusiveRange(2, 7));
      expect(encoder.publishedSubmission!.scene.drawCalls, 3);
      expect(encoder.uploadBacklogBytes, 0);
    },
  );

  test(
    'one indivisible asset above the target makes progress without joining another',
    () {
      final encoder = ScenePacketEncoder(viewId: 2, uploadBudgetBytes: 1500);
      final scene = texturedScene(2, edge: 64);
      var completed = false, largePackets = 0;
      for (var i = 0; i < 8; i++) {
        final packet = encoder.encode(capture(scene));
        if (packet.uploadedBytes > 1500) {
          largePackets++;
          expect(packet.uploadedBytes, 16384);
        }
        encoder.accept(packet);
        if (packet.ready) {
          completed = true;
          break;
        }
      }
      expect(completed, isTrue);
      expect(largePackets, 2);
    },
  );

  test(
    'failed upload retries its chunk and camera reversal abandons the backlog',
    () {
      final encoder = ScenePacketEncoder(viewId: 3, uploadBudgetBytes: 1500);
      final old = Scene()..add(Mesh(PlaneGeometry(), UnlitMaterial()));
      encoder.accept(encoder.encode(capture(old)));
      final scene = texturedScene(3);
      final first = encoder.encode(capture(scene));
      expect(first.ready, isFalse);
      encoder.reject(first);
      final retry = encoder.encode(capture(scene));
      expect(retry.ready, isFalse);
      expect(retry.uploadedBytes, lessThanOrEqualTo(1500));
      encoder.accept(retry);
      final reversal = encoder.encode(capture(old));
      expect(reversal.ready, isTrue);
      encoder.accept(reversal);
      expect(encoder.uploadBacklogBytes, 0);
      expect(encoder.stagedBytes, 0);
    },
  );

  test(
    'upload targets cannot disable progress or raise the hard safety limit',
    () {
      for (final bytes in [0, -1, 64 * 1024 * 1024 + 1]) {
        expect(
          () => ScenePacketEncoder(viewId: 4, uploadBudgetBytes: bytes),
          throwsArgumentError,
        );
      }
      final encoder = ScenePacketEncoder(viewId: 4);
      expect(() => encoder.uploadBudgetBytes = 0, throwsArgumentError);
      expect(encoder.uploadBudgetBytes, 64 * 1024 * 1024);
    },
  );
}
