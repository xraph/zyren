import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('color ranges publish atomically and preserve captured colors', () {
    final mesh = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 3);
    final first = mesh.captureInstances();
    expect(first.colors, List.filled(3, const Color3(1, 1, 1)));
    final colors = [const Color3(.2, .4, .6), const Color3(.8, .5, .1)];
    mesh.setColors(1, colors);
    final tinted = mesh.captureInstances();
    colors[0] = const Color3(0, 0, 0);
    expect(mesh.getColor(1), const Color3(.2, .4, .6));
    expect(first.colors[1], const Color3(1, 1, 1));
    expect(() => tinted.colors.clear(), throwsUnsupportedError);
    final revision = mesh.revision;
    mesh.setColor(1, const Color3(.2, .4, .6));
    mesh.setColors(3, []);
    expect(mesh.revision, revision);
    expect(mesh.captureInstances(), same(tinted));
    for (final invalid in [
      const Color3(-.1, 1, 1),
      const Color3(1, 1.1, 1),
      const Color3(double.nan, 1, 1),
      const Color3(1, double.infinity, 1),
    ]) {
      expect(
        () => mesh.setColors(0, [const Color3(0, 0, 0), invalid]),
        throwsArgumentError,
      );
      expect(mesh.captureInstances(), same(tinted));
      expect(mesh.getColor(0), const Color3(1, 1, 1));
    }
    expect(() => mesh.setColor(-1, const Color3(0, 0, 0)), throwsRangeError);
    expect(() => mesh.setColors(2, colors), throwsRangeError);
    expect(() => mesh.getColor(3), throwsRangeError);
  });

  test('color and transform ranges merge without changing mesh bounds', () {
    final mesh = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 4);
    final first = mesh.captureInstances();
    mesh.setColor(1, const Color3(1, 0, 0));
    mesh.setTransform(
      2,
      Mat4.compose(const Vec3(4, 0, 0), Quat.identity, Vec3.one),
    );
    mesh.setColor(3, const Color3(0, 0, 1));
    final range = mesh.captureInstances().changesSince(first)!.single;
    expect((range.first, range.count), (1, 3));
    expect(mesh.bounds.minimum.x, -.5);
    expect(mesh.bounds.maximum.x, 4.5);
    final current = mesh.captureInstances();
    for (var i = 0; i < 65; i++) {
      mesh.setColor(0, Color3(i / 65, 0, 0));
    }
    expect(mesh.captureInstances().changesSince(current), isNull);
  });

  test('color packets retain hidden edits and independent view baselines', () {
    final mesh = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 2);
    final scene = Scene()..add(mesh);
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(7, 7),
    );
    final a = ScenePacketEncoder(viewId: 1), b = ScenePacketEncoder(viewId: 2);
    final frozen = capture();
    final initial = a.encode(frozen);
    a.accept(initial);
    b.accept(b.encode(frozen));
    mesh.setColor(1, const Color3(0, 1, 0));
    final tint = a.encode(capture());
    expect(tint.uploadedBytes, 128);
    a.accept(tint);
    expect(b.encode(frozen).uploadedBytes, 0);
    mesh.count = 0;
    mesh.setColor(0, const Color3(1, 0, 0));
    final hidden = a.encode(capture());
    expect(hidden.uploadedBytes, 0);
    a.accept(hidden);
    mesh.count = 1;
    final shown = a.encode(capture());
    expect(shown.uploadedBytes, 128);
    a.accept(shown);
    expect(a.encode(frozen).uploadedBytes, 256);
  });
}
