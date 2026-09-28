import 'dart:typed_data';
import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Future<void> verifyShadows(NativeGpuBackend backend) async {
  final scene = Scene()..background = const Color3(0, 0, 0);
  final receiver = scene.add(
    Mesh(
      PlaneGeometry(width: 5, height: 5),
      StandardMaterial(baseColor: const Color3(1, 1, 1), roughness: 1),
    )..receiveShadow = true,
  );
  final geometry = BoxGeometry(width: .5, height: .5, depth: .5, dynamic: true);
  final caster = scene.add(
    Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0)))
      ..position = const Vec3(0, 0, 1),
  );
  final settings = DirectionalShadow(cascades: 2, distance: 10, normalBias: 0);
  final light = scene.add(
    DirectionalLight(shadow: settings)..lookAt(const Vec3(.6, 0, -.8)),
  );
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
  Future<int> probe() async {
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(31, 31),
              ),
            )
            as ReadbackOutput;
    return output.image.pixels[(15 * 31 + 20) * 4];
  }

  final initial = await backend.shadowStats();
  final lit = await probe();
  expect(lit, greaterThan(100));
  caster.castShadow = true;
  expect(await probe(), lessThan(5));
  var stats = await backend.shadowStats();
  expect(stats.atlasCount, 1);
  expect(stats.residentBytes, 16 * 1024 * 1024);
  expect(stats.renderedViews, initial.renderedViews + 4);
  await probe();
  expect((await backend.shadowStats()).renderedViews, stats.renderedViews);
  expect((await backend.shadowStats()).reusedFrames, stats.reusedFrames + 1);
  light.invalidateShadow();
  await probe();
  expect((await backend.shadowStats()).renderedViews, stats.renderedViews + 2);
  receiver.receiveShadow = false;
  expect(await probe(), closeTo(lit, 1));
  receiver.receiveShadow = true;
  caster.position = const Vec3(-2, 0, 1);
  expect(await probe(), closeTo(lit, 1));
  caster.position = const Vec3(0, 0, 1);
  expect(await probe(), lessThan(5));
  final positions = geometry.positions.toList();
  geometry.updateAttribute(
    VertexSemantic.position,
    Float32List.fromList([
      for (var i = 0; i < positions.length; i++)
        positions[i] + (i % 3 == 0 ? -2 : 0),
    ]),
  );
  expect(await probe(), closeTo(lit, 1));
  geometry.updateAttribute(
    VertexSemantic.position,
    Float32List.fromList(positions),
  );
  expect(await probe(), lessThan(5));
  caster.scale = const Vec3(-1, 1, 1);
  final alpha = TextureMap(
    image: TextureImage.rgba(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList([255, 255, 255, 128]),
    ),
  );
  caster.material = UnlitMaterial(
    colorMap: alpha,
    alphaMode: MaterialAlphaMode.mask,
    alphaCutoff: .6,
    side: MaterialSide.front,
  );
  expect(await probe(), closeTo(lit, 1), reason: 'masked holes do not cast');
  caster.material = UnlitMaterial(
    colorMap: alpha,
    alphaMode: MaterialAlphaMode.mask,
    alphaCutoff: .4,
    side: MaterialSide.front,
  );
  expect(
    await probe(),
    lessThan(5),
    reason: 'mirrored opaque mask pixels cast',
  );
  caster.material = UnlitMaterial(
    colorMap: alpha,
    alphaMode: MaterialAlphaMode.mask,
    alphaCutoff: .4,
    opacity: .5,
  );
  expect(await probe(), closeTo(lit, 1), reason: 'mask honors opacity');
  caster.material = UnlitMaterial();
  light.shadow = settings.copyWith(strength: 0);
  expect(await probe(), closeTo(lit, 1));
  light.shadow = settings;
  receiver.material = StandardMaterial(
    emissive: const Color3(.25, 0, 0),
    roughness: 1,
  );
  expect(await probe(), closeTo(137, 2), reason: 'shadow preserves emission');
  receiver.material = StandardMaterial(
    baseColor: const Color3(1, 1, 1),
    roughness: 1,
  );
  light.shadow = DirectionalShadow(
    cascades: 3,
    distance: 20,
    splitLambda: 0,
    normalBias: 0,
    filterRadius: 0,
  );
  camera.target = const Vec3(.75, 0, 0);
  for (final depth in [3.0, 6.1, 6.72, 6.74, 9.0, 12.8, 13.35, 13.38, 16.0]) {
    camera.position = Vec3(.75, 0, depth);
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(31, 31),
                colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
              ),
            )
            as ReadbackOutput;
    expect(
      output.image.pixels[(15 * 31 + 15) * 4],
      lessThan(5),
      reason: 'cascade interval or blend at depth $depth',
    );
  }
  camera.target = Vec3.zero;
  camera.position = const Vec3(0, 0, 5);
  light.visible = false;
  final spot = scene.add(
    SpotLight(intensity: 8, shadow: SpotShadow(normalBias: 0))
      ..position = const Vec3(-.75, 0, 2)
      ..lookAt(const Vec3(.75, 0, 0)),
  );
  caster.castShadow = false;
  final spotLit = await probe();
  expect(spotLit, greaterThan(100));
  caster.castShadow = true;
  expect(await probe(), lessThan(5), reason: 'spot shadow');
  spot.visible = false;
  final point = scene.add(
    PointLight(intensity: 8, shadow: PointShadow(normalBias: 0))
      ..position = const Vec3(-.75, 0, 2),
  );
  caster.castShadow = false;
  final pointLit = await probe();
  expect(pointLit, greaterThan(100));
  caster.castShadow = true;
  expect(await probe(), lessThan(5), reason: 'point negative Z face');
  final baseCamera = camera.position;
  final baseTarget = camera.target;
  final baseUp = camera.up;
  final basePoint = point.position;
  final root = scene.add(Group());
  scene.remove(receiver);
  scene.remove(caster);
  scene.remove(point);
  root.add(receiver);
  root.add(caster);
  root.add(point);
  for (final rotation in [
    Quat.axisAngle(const Vec3(0, 1, 0), -math.pi / 2),
    Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
    Quat.axisAngle(const Vec3(1, 0, 0), math.pi / 2),
    Quat.axisAngle(const Vec3(1, 0, 0), -math.pi / 2),
    Quat.axisAngle(const Vec3(0, 1, 0), math.pi),
    Quat.identity,
  ]) {
    root.quaternion = rotation;
    camera.position = rotation.rotate(baseCamera);
    camera.target = rotation.rotate(baseTarget);
    camera.up = rotation.rotate(baseUp);
    expect(await probe(), lessThan(5), reason: 'all six point faces');
    caster.castShadow = false;
    expect(await probe(), closeTo(pointLit, 2));
    caster.castShadow = true;
  }
  const origin = Vec3(6378137, 9000000, -12000000);
  root.position = origin;
  camera.position = baseCamera + origin;
  camera.target = baseTarget + origin;
  expect(
    await probe(),
    lessThan(5),
    reason: 'camera-relative planet-scale position',
  );
  root.position = Vec3.zero;
  camera.position = baseCamera;
  camera.target = baseTarget;
  point.position = basePoint;
  point.shadow = null;
  expect(await probe(), closeTo(pointLit, 1));
  expect((await backend.shadowStats()).residentBytes, 0);
  root.remove(caster);
  root.remove(receiver);
  await probe();
}
