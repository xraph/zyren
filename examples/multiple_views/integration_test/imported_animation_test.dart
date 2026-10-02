import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../../packages/zyren_gltf/test/support/animated_fixture.dart';

final class _Source implements ByteSourceResolver {
  final Uint8List bytes;
  _Source(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}

List<int> center(FrameOutput output) => (output as ReadbackOutput).image.pixels
    .sublist((15 * 31 + 15) * 4, (15 * 31 + 15) * 4 + 4);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('imported poses crossfade and deform on the native device', (
    tester,
  ) async {
    final assets = AssetScope(
      services: AssetServices(
        resolver: _Source(animatedModel(bindPosition: 2)),
      ),
    );
    addTearDown(assets.close);
    final model = await assets.load(Gltf.asset('animated.glb')).result;
    final instance = model.instantiate();
    final scene = Scene()
      ..background = const Color3(0, 0, 0)
      ..add(instance);
    final timeline = SceneTimelinePlugin.mixed(
      duration: const Duration(seconds: 1),
      base: modelRestClip(instance),
    );
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      backendFactory: NativeBackend.create,
      plugins: [timeline],
    );
    addTearDown(engine.dispose);
    final expectedBackend = Platform.isAndroid || Platform.isLinux
        ? 'vulkan'
        : Platform.isWindows
        ? 'dx12'
        : 'metal';
    expect(engine.capabilities.backend?.toLowerCase(), expectedBackend);
    Future<FrameOutput> draw(Duration delta) => engine.renderFrame(
      elapsed: Duration.zero,
      time: FrameTime(delta: delta),
      width: 31,
      height: 31,
    );
    const end = Duration(seconds: 1);
    final rest = timeline.createAction(modelRestClip(instance), weight: 1);
    final moving = timeline.createAction(
      modelClip(instance, model.animations.single),
    );
    expect(center(await draw(Duration.zero)), [255, 0, 0, 255]);
    rest.crossFadeTo(moving, end);
    moving.pause();
    moving.seek(end);
    await draw(Duration.zero);
    final mixed = await draw(const Duration(milliseconds: 500));
    final mesh = instance.nodes[0]!.children.single as Mesh;
    expect(mesh.geometry.positions.first, 3);
    expect(instance.nodes[1]!.position.x, 4);
    expect(mixed.stats.uploadedBytes, greaterThan(0));
    expect(center(mixed), [0, 0, 0, 255]);
    await draw(const Duration(milliseconds: 500));
    expect(mesh.geometry.positions.first, 7);
    moving.crossFadeTo(rest, end);
    rest.pause();
    await draw(Duration.zero);
    expect(center(await draw(end)), [255, 0, 0, 255]);
    final additive = timeline.createAction(
      modelClip(instance, model.animations.single),
      additive: true,
      weight: .5,
      loop: true,
      reverse: true,
    )..play();
    await draw(Duration.zero);
    await draw(const Duration(milliseconds: 500));
    expect(mesh.geometry.positions.first, 1);
    await draw(const Duration(milliseconds: 500));
    expect(additive.position, end);
    expect(mesh.geometry.positions.first, 3);
    additive.dispose();
    expect(center(await draw(Duration.zero)), [255, 0, 0, 255]);
    expect((await draw(Duration.zero)).stats.uploadedBytes, 0);
    // Pixel assertions above deliberately request readback, unlike presentation.
    // ignore: avoid_print
    print(
      'IMPORTED_ANIMATION backend=${engine.capabilities.backend} crossfade=pass additive=pass reverseLoop=pass unchangedUploadBytes=0',
    );
  });
}
