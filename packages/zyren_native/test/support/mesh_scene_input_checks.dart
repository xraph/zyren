import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

const sceneInputFixture =
    '''
${MeshShaderInterface.wgsl}
${MeshShaderInterface.sceneInputs}
@vertex fn vertex(@location(0) p:vec3<f32>) -> @builtin(position) vec4<f32> {
  return mesh.mvp*vec4(p,1.);
}
@fragment fn fragment(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> {
  // Sample a fixed unobstructed background point. HDR values stay above one.
  let pixel=vec2(meshScene.viewport.x*.25,meshScene.viewport.y*.75);
  let depth=meshSceneDepth(pixel);
  if (!meshSceneHasSurface(depth)) { return vec4(1.,0.,1.,1.); }
  let position=meshScenePosition(pixel,depth);
  if (abs(position.z+4.)>.01) { return vec4(1.,1.,0.,1.); }
  return vec4(meshSceneColor(pixel).rgb*.25,1.);
}
''';

Future<void> verifyMeshSceneInputs(
  NativeBackend backend, {
  double captureScale = 1,
}) async {
  final viewB = backend.createView(),
      shaders = backend.createShaderCompiler(),
      materials = backend.createMaterialCompiler();
  final program = await shaders.compileMesh(
    ShaderSource.wgsl(sceneInputFixture),
    sceneInputs: MeshSceneInputs.opaqueColorDepth,
  );
  final module = await shaders.compile(ShaderSource.wgsl(sceneInputFixture));
  final retained = await materials.compile(
    MeshShaderDescriptor(
      program: module,
      sceneInputs: MeshSceneInputs.opaqueColorDepth,
    ),
  );
  final scene = Scene()
    ..renderSettings = RenderSettings(opaqueCaptureScale: captureScale);
  final camera = OrthographicCamera(
    verticalSize: 2,
    near: .1,
    far: 10,
    position: const Vec3(0, 0, 3),
  );
  Camera activeCamera = camera;
  final background = scene.add(
    Mesh(
      PlaneGeometry(width: 2, height: 2),
      StandardMaterial(
        baseColor: const Color3(0, 0, 0),
        metallic: 1,
        emissive: const Color3(1, 0, 0),
        emissiveIntensity: 4,
      ),
    )..position = const Vec3(0, 0, -1),
  );
  final surface = scene.add(
    Mesh(PlaneGeometry(width: 2, height: 2), ShaderMaterial(program)),
  );
  final marker = scene.add(
    Mesh(
      PlaneGeometry(width: .25, height: .25),
      UnlitMaterial(color: const Color3(0, 1, 0)),
    )..position = const Vec3(.6, .6, .5),
  );
  final alpha = scene.add(
    Mesh(
      PlaneGeometry(width: .3, height: .3),
      UnlitMaterial(
        color: const Color3(0, 0, 1),
        alphaMode: MaterialAlphaMode.blend,
        opacity: .5,
      ),
    )..position = const Vec3(0, 0, .5),
  );
  final sampledAlpha = scene.add(
    Mesh(
      PlaneGeometry(width: .3, height: .3),
      UnlitMaterial(
        color: const Color3(0, 0, 1),
        alphaMode: MaterialAlphaMode.blend,
        opacity: .5,
      ),
    )..position = const Vec3(-.5, -.5, .5),
  );
  List<int> pixel(ReadbackOutput output, double x, double y) {
    final width = output.image.size.width, height = output.image.size.height;
    final offset = (((y * height).floor() * width) + (x * width).floor()) * 4;
    return output.image.pixels.sublist(offset, offset + 4);
  }

  Future<ReadbackOutput> draw(
    NativeBackend view,
    int size, {
    int samples = 1,
    bool hdr = true,
  }) async =>
      await view.render(
            FrameSubmission.capture(
              scene: scene,
              camera: activeCamera,
              size: PhysicalSize(size, size),
              colorPipeline: hdr
                  ? ColorPipeline(
                      toneMapping: ToneMapping.linear,
                      sampleCount: samples,
                    )
                  : null,
            ),
          )
          as ReadbackOutput;
  try {
    expect(
      backend.capabilities.supports(RenderFeature.meshSceneInputs),
      isTrue,
    );
    for (final mode in [DepthStrategy.standard, DepthStrategy.reversed]) {
      camera.depthStrategy = mode;
      for (final samples in [
        1,
        if (backend.capabilities.limits.sampleCounts.contains(4)) 4,
      ]) {
        for (final shader in [program, retained]) {
          surface.material = ShaderMaterial(shader);
          background.material = StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            metallic: 1,
            emissive: const Color3(1, 0, 0),
            emissiveIntensity: 4,
          );
          final first = await draw(backend, 64, samples: samples);
          expect(
            (await backend.transmissionStats()).residentBytes,
            (64 * captureScale).ceil() *
                (64 * captureScale).ceil() *
                12 *
                (samples == 4 ? 5 : 1),
          );
          expect(pixel(first, .3, .3), [255, 0, 0, 255]);
          expect(pixel(first, .8, .2), [0, 255, 0, 255]);
          final blend = pixel(first, .5, .5);
          expect(blend[0], closeTo(188, 2));
          expect(blend[2], closeTo(188, 2));
          background.material = StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            metallic: 1,
            emissive: const Color3(0, 1, 0),
            emissiveIntensity: 4,
          );
          final second = await draw(backend, 64, samples: samples);
          expect(pixel(second, .3, .3), [0, 255, 0, 255]);
          expect(pixel(second, .8, .2), pixel(first, .8, .2));
          background.material = StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            metallic: 1,
            emissive: const Color3(0, 0, 1),
            emissiveIntensity: 4,
          );
          final other = await draw(viewB, 96, samples: samples);
          expect(pixel(other, .3, .3), [0, 0, 255, 255]);
          background.material = StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            metallic: 1,
            emissive: const Color3(1, 0, 0),
            emissiveIntensity: 4,
          );
          expect(pixel(await draw(backend, 48, samples: samples), .3, .3), [
            255,
            0,
            0,
            255,
          ]);
        }
      }
    }
    for (final strategy in DepthStrategy.values) {
      activeCamera = PerspectiveCamera(
        position: const Vec3(0, 0, 3),
        near: .1,
        far: 10,
        depthStrategy: strategy,
      );
      expect(pixel(await draw(backend, 64), .3, .3), [255, 0, 0, 255]);
    }
    activeCamera = camera;
    if (captureScale == 1 &&
        backend.capabilities.limits.sampleCounts.contains(4)) {
      final retainedBytes = (await backend.transmissionStats()).residentBytes;
      await expectLater(
        draw(backend, 1536, samples: 4),
        throwsA(isA<SceneException>()),
      );
      expect((await backend.transmissionStats()).residentBytes, retainedBytes);
      expect(pixel(await draw(backend, 48), .3, .3), [255, 0, 0, 255]);
    }
    // Even an SDR consumer receives linear HDR capture values.
    expect(pixel(await draw(backend, 64, hdr: false), .3, .3), [
      255,
      0,
      0,
      255,
    ]);
    sampledAlpha.visible = false;
    alpha.visible = false;
    marker.visible = false;
    surface.visible = false;
    await draw(backend, 64);
    expect((await backend.transmissionStats()).residentBytes, 0);
  } finally {
    await materials.close();
    await shaders.close();
    await viewB.close();
  }
}
