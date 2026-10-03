import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'support/environment_checks.dart'
    show constantEnvironment, smallEnvironment;
import 'support/frame_graph_checks.dart' show createFrameEffect;
import 'package:zyren_native/zyren_native.dart';

BufferGeometry largeGeometry(int count) {
  final positions = Float32List(count * 3)
    ..setAll(0, [-1, -1, 0, 1, -1, 0, 0, 1, 0]);
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
  for (final instanced in [false, true]) {
    test(
      'staged ${instanced ? "instances" : "geometry"} survive another view patch',
      () async {
        final owner = await NativeBackend.create();
        final stagingView = owner.createView();
        try {
          final camera = PerspectiveCamera();
          FrameSubmission capture(Scene scene) => FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(16, 16),
          );
          final geometry = BufferGeometry(
            positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2],
            dynamic: true,
          );
          final material = UnlitMaterial(color: const Color3(1, 0, 0));
          final mesh = instanced
              ? InstancedMesh(geometry, material, count: 1)
              : Mesh(geometry, material);
          final scene = Scene()..add(mesh);
          final original = await owner.render(capture(scene)) as ReadbackOutput;
          final old = Scene()
            ..add(
              Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(0, 1, 0))),
            );
          final previous =
              await stagingView.render(capture(old)) as ReadbackOutput;
          final candidate = Scene()
            ..add(instanced ? mesh : Mesh(geometry, material));
          for (var i = 0; i < 2; i++) {
            candidate.add(
              Mesh(largeGeometry(600000), UnlitMaterial())
                ..position = Vec3(100.0 + i, 0, 0),
            );
          }
          final fixedCandidate = capture(candidate);
          final staged =
              await stagingView.render(fixedCandidate) as ReadbackOutput;
          expect(staged.stats.admission!.candidateReady, isFalse);
          expect(staged.image.pixels, previous.image.pixels);
          if (instanced) {
            scene.add(mesh);
            (mesh as InstancedMesh).setTransform(
              0,
              Mat4.compose(const Vec3(10, 0, 0), Quat.identity, Vec3.one),
            );
          } else {
            geometry.updateAttribute(
              VertexSemantic.position,
              Float32List.fromList([9, -1, 0, 11, -1, 0, 10, 1, 0]),
            );
          }
          final patched = await owner.render(capture(scene)) as ReadbackOutput;
          expect(patched.image.pixels, isNot(original.image.pixels));
          final published =
              await stagingView.render(fixedCandidate) as ReadbackOutput;
          expect(published.stats.admission!.candidateReady, isTrue);
          expect(published.image.pixels, original.image.pixels);
          await stagingView.close();
          await owner.render(capture(Scene()));
          expect((await owner.resourceStats()).residentBytes, 0);
        } on SceneException catch (error) {
          fail('${error.issue}: ${error.issue.cause}');
        } finally {
          await stagingView.close();
          await owner.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }

  test(
    'native staging keeps the published cover while camera moves and recovers on reversal',
    () async {
      final renderer = await NativeRenderer.create();
      try {
        final old = Scene()
          ..add(
            Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(1, 0, 0)))
              ..position = const Vec3(1000000, 0, 0),
          );
        final camera = PerspectiveCamera()
          ..position = const Vec3(1000000, 0, 5)
          ..target = const Vec3(1000000, 0, 0);
        final initial = await renderer.render(
          old,
          camera,
          width: 32,
          height: 32,
        );
        final center = (16 * 32 + 16) * 4;
        expect(initial.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
        final candidate = Scene();
        for (var i = 0; i < 3; i++) {
          candidate.add(
            Mesh(
              largeGeometry(600000),
              UnlitMaterial(color: const Color3(0, 1, 0)),
            )..position = const Vec3(1000000, 0, 0),
          );
        }
        camera.position = const Vec3(1000000.1, 0, 5);
        final staged = await renderer.render(
          candidate,
          camera,
          width: 32,
          height: 32,
        );
        expect(staged.profile!.candidateReady, isFalse);
        expect(staged.profile!.stagedBytes, greaterThan(0));
        expect(staged.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
        camera.position = const Vec3(1000000.2, 0, 5);
        final next = await renderer.render(
          candidate,
          camera,
          width: 32,
          height: 32,
        );
        expect(
          next.profile!.uploadBacklogBytes,
          lessThan(staged.profile!.uploadBacklogBytes!),
        );
        expect(next.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
        final published = await renderer.render(
          candidate,
          camera,
          width: 32,
          height: 32,
        );
        expect(published.profile!.candidateReady, isTrue);
        expect(published.pixels.sublist(center, center + 4), [0, 255, 0, 255]);
        final reversed = await renderer.render(
          old,
          camera,
          width: 32,
          height: 32,
        );
        expect(reversed.profile!.candidateReady, isTrue);
        expect(reversed.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
      } finally {
        await renderer.dispose();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'closed mesh owners remain usable by the published cover and teardown releases them',
    () async {
      final backend = await NativeBackend.create();
      final observer = backend.createView();
      final scope = backend.createResourceScope();
      final compiler = backend.createShaderCompiler();
      try {
        final buffer = await scope.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        await scope.writeBuffer(buffer, Float32List.fromList([1, 0, 0, 1]));
        final program = await compiler.compileMesh(
          ShaderSource.wgsl('''${MeshShaderInterface.wgsl}
@group(1) @binding(0) var<uniform> tint: vec4<f32>;
@vertex fn vertex(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> { return mesh.mvp * vec4(p, 1.); }
@fragment fn fragment() -> @location(0) vec4<f32> { return meshColor(tint); }
'''),
          bindings: ShaderBindings([
            BufferBinding.uniform(0, buffer, group: 1),
          ]),
        );
        final old = Scene()..add(Mesh(BoxGeometry(), ShaderMaterial(program)));
        final camera = PerspectiveCamera();
        Future<ReadbackOutput> draw(Scene scene) async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(16, 16),
                  ),
                )
                as ReadbackOutput;
        final original = await draw(old);
        final candidate = Scene();
        for (var i = 0; i < 3; i++) {
          candidate.add(Mesh(largeGeometry(600000), UnlitMaterial()));
        }
        await program.close().timeout(const Duration(seconds: 2));
        await compiler.close().timeout(const Duration(seconds: 2));
        await scope.close().timeout(const Duration(seconds: 2));
        final staged = await draw(candidate);
        expect(staged.stats.admission!.candidateReady, isFalse);
        expect(
          staged.stats.admission!.presentedIdentities,
          original.stats.admission!.presentedIdentities,
        );
        expect(staged.stats.drawCalls, original.stats.drawCalls);
        expect(staged.stats.triangles, original.stats.triangles);
        expect(staged.image.pixels, original.image.pixels);
        expect((await observer.graphStats()).liveMeshShaders, 1);
        await backend.close().timeout(const Duration(seconds: 2));
        expect((await observer.graphStats()).liveMeshShaders, 0);
        expect((await observer.resourceStats()).residentBytes, 0);
      } on SceneException catch (error) {
        fail("${error.issue}: ${error.issue.cause}");
      } finally {
        await backend.close();
        await observer.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'impossible overlap rejects before upload and preserves both views',
    () async {
      final backend = await NativeBackend.create();
      final second = backend.createView();
      try {
        final camera = PerspectiveCamera();
        final old = Scene()
          ..add(
            Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(1, 0, 0))),
          );
        Future<FrameOutput> draw(NativeBackend view, Scene scene) =>
            view.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(16, 16),
              ),
            );
        await draw(backend, old);
        await draw(second, old);
        await backend.configureResourceBudget(20 * 1024 * 1024);
        final before = await backend.resourceStats();
        final candidate = Scene();
        for (var i = 0; i < 3; i++) {
          candidate.add(Mesh(largeGeometry(600000), UnlitMaterial()));
        }
        await expectLater(
          draw(backend, candidate),
          throwsA(isA<SceneException>()),
        );
        final after = await backend.resourceStats();
        expect(after.uploadedBytes, before.uploadedBytes);
        expect(after.residentBytes, before.residentBytes);
        final a = await draw(backend, old) as ReadbackOutput;
        final b = await draw(second, old) as ReadbackOutput;
        expect(a.image.pixels, b.image.pixels);
        expect(a.stats.admission!.candidateReady, isTrue);
      } finally {
        await second.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'closed environment and graph bindings transfer to the native cover',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      try {
        final map = await EnvironmentMap.fromEquirectangular(
          constantEnvironment(.5, .25, 1),
          resources: scope,
          quality: smallEnvironment,
        );
        final environment = Environment(map: map);
        final graph = await createFrameEffect(backend, 16, 16);
        final old = Scene()
          ..add(
            Mesh(BoxGeometry(), StandardMaterial(metallic: 1, roughness: .5)),
          );
        final camera = PerspectiveCamera();
        Future<ReadbackOutput> draw(
          Scene scene, {
          Environment? environment,
          CompiledGraph? graph,
        }) async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(16, 16),
                    environment: environment,
                    graph: graph,
                  ),
                )
                as ReadbackOutput;
        final original = await draw(
          old,
          environment: environment,
          graph: graph,
        );
        await map.close().timeout(const Duration(seconds: 2));
        await scope.close().timeout(const Duration(seconds: 2));
        await graph.close().timeout(const Duration(seconds: 2));
        final candidate = Scene();
        for (var i = 0; i < 3; i++) {
          candidate.add(Mesh(largeGeometry(600000), UnlitMaterial()));
        }
        final staged = await draw(candidate);
        expect(staged.stats.admission!.candidateReady, isFalse);
        expect(staged.image.pixels, original.image.pixels);
        expect(
          staged.stats.computeDispatches,
          original.stats.computeDispatches,
        );
        await draw(candidate);
        final published = await draw(candidate);
        expect(published.stats.admission!.candidateReady, isTrue);
        expect((await backend.graphStats()).liveGraphs, 0);
      } on SceneException catch (error) {
        fail("${error.issue}: ${error.issue.cause}");
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'closed screen effects keep rendering until the replacement is published',
    () async {
      final backend = await NativeBackend.create();
      final shaders = backend.createShaderCompiler();
      final materials = backend.createMaterialCompiler();
      try {
        final effect = await materials.compileEffect(
          PostProcessDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n'
                '@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {return vec4<f32>(1.,0.,0.,1.);}',
              ),
            ),
          ),
        );
        final old = Scene()..renderSettings = RenderSettings(effects: [effect]);
        final camera = PerspectiveCamera();
        Future<ReadbackOutput> draw(Scene scene) async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(16, 16),
                  ),
                )
                as ReadbackOutput;
        final original = await draw(old);
        expect(original.image.pixels.sublist(0, 4), [255, 0, 0, 255]);
        await materials.close().timeout(const Duration(seconds: 2));
        await shaders.close().timeout(const Duration(seconds: 2));
        expect(effect.isClosed, isTrue);
        expect((await backend.graphStats()).liveMaterials, 1);
        final candidate = Scene();
        for (var i = 0; i < 3; i++) {
          candidate.add(Mesh(largeGeometry(600000), UnlitMaterial()));
        }
        final staged = await draw(candidate);
        expect(staged.stats.admission!.candidateReady, isFalse);
        expect(staged.image.pixels, original.image.pixels);
        await draw(candidate);
        final published = await draw(candidate);
        expect(published.stats.admission!.candidateReady, isTrue);
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await backend.close();
        await materials.close();
        await shaders.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'resizing a retained graph keeps presenting and staging makes progress',
    () async {
      final backend = await NativeBackend.create();
      try {
        final graph = await createFrameEffect(backend, 16, 16);
        final old = Scene()..background = const Color3(1, 0, 0);
        final camera = PerspectiveCamera();
        Future<ReadbackOutput> draw(
          Scene scene,
          int width,
          int height, {
          CompiledGraph? graph,
        }) async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(width, height),
                    graph: graph,
                  ),
                )
                as ReadbackOutput;
        await draw(old, 16, 16, graph: graph);
        await graph.close();
        final candidate = Scene();
        for (var i = 0; i < 3; i++) {
          candidate.add(Mesh(largeGeometry(600000), UnlitMaterial()));
        }
        final first = await draw(candidate, 24, 12);
        expect(first.stats.admission!.candidateReady, isFalse);
        expect(first.image.size.width, 24);
        expect(first.stats.profile!.resizeCompositeDraws, 1);
        expect(first.stats.drawCalls, graph.drawCalls + 1);
        for (var i = 0; i < first.image.pixels.length; i += 4) {
          expect(first.image.pixels.sublist(i, i + 4), [255, 0, 255, 255]);
        }
        camera.position = const Vec3(.1, 0, 5);
        final second = await draw(candidate, 30, 10);
        expect(
          second.stats.admission!.uploadBacklogBytes,
          lessThan(first.stats.admission!.uploadBacklogBytes),
        );
        expect(second.image.pixels.sublist(0, 4), [255, 0, 255, 255]);
        final published = await draw(candidate, 30, 10);
        expect(published.stats.admission!.candidateReady, isTrue);
        expect((await backend.graphStats()).liveGraphs, 0);
        expect(
          (await backend.inspectGpu()).allocations.every(
            (a) => a.kind == 'geometry',
          ),
          isTrue,
        );
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
