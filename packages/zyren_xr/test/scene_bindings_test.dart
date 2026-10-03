import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_xr/src/models.dart';
import 'package:zyren_xr/src/scene_bindings.dart';

XrSnapshot snapshot({
  String tracking = 'normal',
  bool anchor = true,
  int revision = 1,
}) => XrSnapshot.fromMessage({
  'state': 'running',
  'revision': revision,
  'nativeTimestamp': 10.1,
  'frame': {
    'timestamp': 10.0,
    'cameraTransform': XrPose.identity().matrix,
    'tracking': tracking,
    'intrinsics': [1, 0, 0, 0, 1, 0, 0, 0, 1],
    'imageWidth': 10,
    'imageHeight': 10,
    'omittedPlanes': 0,
    'planes': [],
    'anchors': [
      if (anchor)
        {
          'id': 'anchor',
          'transform': [...XrPose.identity().matrix.take(12), 2, 3, 4, 1],
        },
    ],
  },
});

void main() {
  test(
    'anchor preserves object/source identity through parent transforms and tracking loss',
    () {
      final root = Group()..position = const Vec3(10, 0, 0);
      final object = Group()..position = const Vec3(0, 1, 0);
      final bindings = XrSceneBindings(
        sessionId: 'session',
        root: root,
        originEpoch: 0,
      );
      final binding = bindings.bind(
        anchorId: 'anchor',
        object: object,
        sourceId: 'asset:pump',
      );
      final source = XrPose([
        ...XrPose.identity().matrix.take(12),
        20,
        0,
        0,
        1,
      ]);
      bindings.update(
        snapshot(),
        sessionId: 'session',
        originEpoch: 0,
        sceneFromSession: source,
      );
      expect(object.worldMatrix.storage.sublist(12, 15), [22, 4, 4]);
      expect(binding.runtimeObjectId, object.id);
      expect(binding.sourceId, 'asset:pump');
      expect(binding.tracked, isTrue);
      bindings.update(
        snapshot(tracking: 'limited'),
        sessionId: 'session',
        originEpoch: 0,
      );
      expect(binding.tracked, isFalse);
      expect(bindings.bindings, hasLength(1));
      bindings.update(snapshot(), sessionId: 'session', originEpoch: 0);
      expect(binding.tracked, isTrue);
      bindings.dispose();
      expect(object.parent, isNull);
      expect(root.children, isEmpty);
    },
  );

  test(
    'new anchors wait for observation; removal and reset detach without disposing content',
    () {
      final root = Group(), object = Group();
      final bindings = XrSceneBindings(
        sessionId: 'session',
        root: root,
        originEpoch: 0,
      );
      bindings.bind(anchorId: 'anchor', object: object);
      expect(
        bindings.update(
          snapshot(anchor: false),
          sessionId: 'session',
          originEpoch: 0,
        ),
        isEmpty,
      );
      expect(bindings.bindings, hasLength(1));
      bindings.update(snapshot(), sessionId: 'session', originEpoch: 0);
      expect(
        bindings.update(
          snapshot(anchor: false),
          sessionId: 'session',
          originEpoch: 0,
        ),
        ['anchor'],
      );
      expect(object.parent, isNull);
      bindings.bind(anchorId: 'anchor', object: object);
      expect(
        bindings.update(
          snapshot(revision: 2),
          sessionId: 'session',
          originEpoch: 1,
        ),
        ['anchor'],
      );
      expect(root.children, isEmpty);
      expect(
        () => bindings.update(snapshot(), sessionId: 'session', originEpoch: 0),
        throwsA(isA<XrException>()),
      );
    },
  );

  test('foreign sessions and nonrigid roots fail before changing bindings', () {
    final root = Group(), object = Group();
    final bindings = XrSceneBindings(
      sessionId: 'session',
      root: root,
      originEpoch: 0,
    );
    bindings.bind(anchorId: 'anchor', object: object);
    expect(
      () => bindings.update(snapshot(), sessionId: 'other', originEpoch: 0),
      throwsA(isA<XrException>()),
    );
    root.scale = const Vec3(2, 1, 1);
    expect(
      () => bindings.update(snapshot(), sessionId: 'session', originEpoch: 0),
      throwsArgumentError,
    );
    expect(bindings.bindings.single.tracked, isFalse);
    expect(
      () => bindings.bind(anchorId: 'other', object: object),
      throwsArgumentError,
    );
  });
}
