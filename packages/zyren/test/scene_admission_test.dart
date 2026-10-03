import 'dart:typed_data';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

BufferGeometry largeGeometry(int count) {
  final positions = Float32List(count * 3);
  positions.setAll(0, [-1, -1, 0, 1, -1, 0, 0, 1, 0]);
  final normals = Float32List(count * 3);
  for (var i = 2; i < normals.length; i += 3) {
    normals[i] = 1;
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: [0, 1, 2],
  );
}

void main() {
  test(
    'large candidate stages while retaining complete cover and current camera',
    () {
      final encoder = ScenePacketEncoder(viewId: 1);
      final old = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
      final camera = PerspectiveCamera()
        ..position = const Vec3(1000000, 0, 5)
        ..target = const Vec3(1000000, 0, 0);
      old.children.single.position = const Vec3(1000000, 0, 0);
      FrameSubmission capture(Scene scene) => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(32, 32),
      );
      final initial = encoder.encode(capture(old));
      encoder.accept(initial);
      final published = encoder.publishedRevision;
      final candidate = Scene();
      for (var i = 0; i < 3; i++) {
        candidate.add(
          Mesh(largeGeometry(600000), UnlitMaterial())
            ..position = const Vec3(1000000, 0, 0),
        );
      }
      camera.position = const Vec3(1000001, 0, 5);
      final first = encoder.encode(capture(candidate));
      expect(first.ready, isFalse);
      expect(first.presentedIdentities, initial.presentedIdentities);
      expect(first.submission.camera.origin, camera.position.storage);
      expect(first.uploadedBytes, lessThanOrEqualTo(64 * 1024 * 1024));
      expect(first.uploadBacklogBytes, greaterThan(0));
      encoder.accept(first);
      expect(encoder.publishedRevision, published);
      camera.position = const Vec3(1000000.5, 0, 5);
      final second = encoder.encode(capture(candidate));
      expect(second.ready, isFalse);
      expect(second.uploadBacklogBytes, lessThan(first.uploadBacklogBytes));
      encoder.accept(second);
      final finalPacket = encoder.encode(capture(candidate));
      expect(finalPacket.ready, isTrue);
      encoder.accept(finalPacket);
      expect(encoder.uploadBacklogBytes, 0);
      expect(encoder.publishedRevision, greaterThan(published));
      expect(encoder.publishedSubmission!.scene.drawCalls, 3);
    },
  );

  test(
    'unaccepted chunks do not advance staging and reversal cancels backlog',
    () {
      final encoder = ScenePacketEncoder(viewId: 2);
      final old = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
      final camera = PerspectiveCamera();
      FrameSubmission capture(Scene scene) => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(16, 16),
      );
      encoder.accept(encoder.encode(capture(old)));
      final candidate = Scene();
      for (var i = 0; i < 2; i++) {
        candidate.add(Mesh(largeGeometry(600000), UnlitMaterial()));
      }
      final failed = encoder.encode(capture(candidate));
      final retry = encoder.encode(capture(candidate));
      expect(retry.uploadedBytes, failed.uploadedBytes);
      expect(() => encoder.accept(failed), throwsStateError);
      encoder.accept(retry);
      final reversal = encoder.encode(capture(old));
      expect(reversal.ready, isTrue);
      encoder.accept(reversal);
      expect(encoder.uploadBacklogBytes, 0);
      expect(encoder.stagedBytes, 0);
    },
  );

  test(
    'index and byte limits stage independently and oversized assets reject recoverably',
    () {
      final camera = PerspectiveCamera();
      FrameSubmission capture(Scene scene) => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(16, 16),
      );
      final encoder = ScenePacketEncoder(viewId: 3);
      final old = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
      encoder.accept(encoder.encode(capture(old)));
      expect(() => largeGeometry(1000001), throwsArgumentError);
      expect(encoder.encode(capture(old)).ready, isTrue);
      final indexed = Scene();
      for (var i = 0; i < 2; i++) {
        indexed.add(
          Mesh(
            BufferGeometry(
              positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
              normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
              indices: Uint32List(1600002),
            ),
            UnlitMaterial(),
          ),
        );
      }
      final indexStage = encoder.encode(capture(indexed));
      expect(indexStage.ready, isFalse);
      encoder.accept(indexStage);
      final indexReady = encoder.encode(capture(indexed));
      expect(indexReady.ready, isTrue);
      encoder.accept(indexReady);
      final textured = Scene();
      for (var i = 0; i < 3; i++) {
        textured.add(
          Mesh(
            PlaneGeometry(),
            UnlitMaterial(
              colorMap: TextureMap(
                image: TextureImage.rgba(
                  width: 2560,
                  height: 2560,
                  pixels: Uint8List(2560 * 2560 * 4),
                ),
              ),
            ),
          ),
        );
      }
      final byteStage = encoder.encode(capture(textured));
      expect(byteStage.ready, isFalse);
      expect(byteStage.uploadedBytes, lessThanOrEqualTo(64 * 1024 * 1024));
      encoder.accept(byteStage);
      expect(encoder.encode(capture(textured)).ready, isTrue);
    },
  );

  test(
    'hidden never-uploaded resources do not enter the candidate reservation',
    () {
      final scene = Scene();
      for (var i = 0; i < 2; i++) {
        scene.add(Mesh(largeGeometry(600000), UnlitMaterial()));
      }
      final hidden = Mesh(largeGeometry(900000), UnlitMaterial())
        ..visible = false;
      scene.add(hidden);
      final encoder = ScenePacketEncoder(viewId: 4);
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(16, 16),
      );
      final first = encoder.encode(capture());
      final data = ByteData.sublistView(first.bytes);
      expect(data.getUint32(0, Endian.little), 4);
      final metadataLength = data.getUint32(4, Endian.little);
      final metadata =
          jsonDecode(utf8.decode(first.bytes.sublist(16, 16 + metadataLength)))
              as Map;
      expect((metadata['resources'] as List).where((r) => r[0] == 0).length, 2);
      encoder.accept(first);
      expect(encoder.encode(capture()).ready, isTrue);
    },
  );
}
