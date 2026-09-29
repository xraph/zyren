import 'dart:convert';
import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';

Future<void> main(List<String> requestedProfiles) async {
  const warmupFrames = 30, measuredFrames = 300;
  double percentile(List<int> sorted, double fraction) =>
      sorted[(sorted.length * fraction).ceil() - 1] / 1000;
  final backend = await NativeBackend.create();
  final results = <Map<String, Object?>>[];
  try {
    for (final width in [640, 1280]) {
      final height = width * 9 ~/ 16;
      for (final profile
          in [
            'ldr',
            'hdr',
            'msaa4',
            'bloom',
            'bloom+spatial',
            'taa',
            'bloom+taa',
            'glass',
            'glass+taa',
            'iridescence',
            'dispersion',
            'area-shadow',
            'texture-rgba',
            'texture-compressed',
            'optics+taa',
          ].where(
            (p) => requestedProfiles.isEmpty || requestedProfiles.contains(p),
          )) {
        final optical = ['iridescence', 'optics+taa'].contains(profile);
        final dispersive = ['dispersion', 'optics+taa'].contains(profile);
        final areaShadow = ['area-shadow', 'optics+taa'].contains(profile);
        TextureImageData? texture;
        if (profile.startsWith('texture-') || profile == 'optics+taa') {
          final decoder = profile == 'texture-rgba'
              ? const NativeTextureDecoder()
              : NativeTextureDecoder.forDevice(backend.capabilities);
          texture = await decoder.decode(
            await File(
              '../../test_assets/compression/colors-uastc.ktx2',
            ).readAsBytes(),
            encoding: TextureEncoding.ktx2Basis,
          );
        }
        final scene = Scene()..background = const Color3(.01, .01, .01);
        final copies = scene.add(
          InstancedMesh(
            SphereGeometry(radius: .09, widthSegments: 16, heightSegments: 8),
            PhysicalMaterial(
              iridescence: optical ? 1 : 0,
              iridescenceThicknessMaximum: 350,
              baseColorMap: texture == null
                  ? null
                  : TextureMap(image: TextureImage.fromData(texture)),
              baseColor: const Color3(.1, .3, .8),
              metallic: .4,
              roughness: .3,
              emissive: const Color3(.1, .05, 0),
              emissiveIntensity: 4,
            ),
            count: 400,
          ),
        );
        copies.setTransforms(
          0,
          List.generate(
            400,
            (i) => Mat4.compose(
              Vec3((i % 20 - 9.5) * .23, (i ~/ 20 - 9.5) * .23, 0),
              Quat.identity,
              Vec3.one,
            ),
          ),
        );
        scene.add(DirectionalLight(intensity: 4));
        copies.castShadow = areaShadow;
        if (areaShadow) {
          scene.add(
            RectAreaLight(
                width: 3,
                height: 2,
                intensity: 3,
                shadow: AreaShadow(far: 20),
              )
              ..position = const Vec3(0, 3, 4)
              ..lookAt(Vec3.zero),
          );
          scene.add(
            Mesh(PlaneGeometry(width: 6, height: 6), StandardMaterial())
              ..position = const Vec3(0, 0, -1)
              ..receiveShadow = true,
          );
        }
        if (profile.startsWith('glass') || dispersive) {
          scene.add(
            Mesh(
              PlaneGeometry(width: 4, height: 4),
              PhysicalMaterial(
                transmission: 1,
                dispersion: dispersive ? 5 : 0,
                thickness: .5,
                roughness: .2,
                attenuationColor: const Color3(.5, .8, 1),
                attenuationDistance: 2,
              ),
            )..position = const Vec3(0, 0, 1),
          );
        }
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 8));
        final effects = PostProcessing(
          bloom: profile.startsWith('bloom') ? BloomOptions() : null,
          antialias: profile.endsWith('spatial'),
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
          plugins: [
            effects,
            if (profile.contains('taa')) TemporalAntialiasing(),
          ],
          onIssue: (issue) => throw SceneException(issue),
        );
        final pipeline = profile == 'ldr'
            ? null
            : ColorPipeline(
                sampleCount:
                    profile == 'hdr' ||
                        profile.contains('taa') ||
                        profile.startsWith('glass') ||
                        optical ||
                        dispersive ||
                        areaShadow ||
                        profile.startsWith('texture-')
                    ? 1
                    : 4,
              );
        try {
          Future<FrameOutput> frame() => engine.renderFrame(
            elapsed: Duration.zero,
            width: width,
            height: height,
            colorPipeline: pipeline,
          );
          await frame();
          await frame();
          await frame();
          final temporalBefore = await backend.temporalStats();
          final transmissionBefore = await backend.transmissionStats();
          final resident = await backend.resourceStats();
          final shadowsBefore = await backend.shadowStats();
          final times = <int>[], builds = <int>[];
          FrameStats? last;
          for (var i = 0; i < warmupFrames + measuredFrames; i++) {
            camera.position = Vec3(i * .0001, 0, 8);
            final timer = Stopwatch()..start();
            final output = await frame();
            timer.stop();
            last = output.stats;
            if (last.uploadedBytes != 0 ||
                last.readbackBytes != width * height * 4 ||
                last.gpuTime != null) {
              throw StateError(
                'Frame upload/readback/timestamp invariant changed.',
              );
            }
            if (i >= warmupFrames) {
              times.add(timer.elapsedMicroseconds);
              builds.add(last.cpuBuildTime.inMicroseconds);
            }
          }
          final temporalAfter = await backend.temporalStats();
          final transmissionAfter = await backend.transmissionStats();
          if (transmissionAfter.residentBytes !=
              transmissionBefore.residentBytes) {
            throw StateError(
              'Transmission capture grew during steady rendering.',
            );
          }
          if (temporalBefore.residentBytes != temporalAfter.residentBytes) {
            throw StateError(
              'Temporal allocations grew during steady rendering.',
            );
          }
          final shadowsAfter = await backend.shadowStats();
          if (shadowsAfter.residentBytes != shadowsBefore.residentBytes ||
              shadowsAfter.renderedViews != shadowsBefore.renderedViews) {
            throw StateError(
              'Static area shadows changed during camera motion.',
            );
          }
          final after = await backend.resourceStats();
          if (after.residentBytes != resident.residentBytes ||
              after.liveAllocations != resident.liveAllocations) {
            throw StateError(
              'Effect allocations grew during steady rendering.',
            );
          }
          times.sort();
          builds.sort();
          results.add({
            'profile': profile,
            'width': width,
            'height': height,
            'copies': 400,
            'samples': measuredFrames,
            'warmupFrames': warmupFrames,
            'p50Ms': percentile(times, .5),
            'p95Ms': percentile(times, .95),
            'p99Ms': percentile(times, .99),
            'maxMs': times.last / 1000,
            'p50CaptureMs': percentile(builds, .5),
            'drawCalls': last!.drawCalls,
            'residentResourceBytes': after.residentBytes,
            'textureFormat': texture?.descriptor.format.name,
            'texturePayloadBytes': texture?.descriptor.byteLength ?? 0,
            'shadowBytes': shadowsAfter.residentBytes,
            'shadowViewsRenderedDuringMeasurement':
                shadowsAfter.renderedViews - shadowsBefore.renderedViews,
            'temporalBytes': temporalAfter.residentBytes,
            'transmissionBytes': transmissionAfter.residentBytes,
            'resourceAllocations': after.liveAllocations,
            'readbackBytes': last.readbackBytes,
            'steadyUploadBytes': last.uploadedBytes,
            'gpuTime': null,
          });
        } finally {
          await engine.dispose();
        }
        if ((await backend.shadowStats()).residentBytes != 0 ||
            (await backend.transmissionStats()).residentBytes != 0 ||
            (await backend.temporalStats()).residentBytes != 0 ||
            (await backend.resourceStats()).residentBytes != 0) {
          throw StateError('Effect resources leaked after view disposal.');
        }
      }
    }
  } finally {
    await backend.close();
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'platform': Platform.operatingSystem,
      'runtime': Platform.version,
      'supportedTextureFormats': backend.capabilities.textureFormats
          .map((f) => f.name)
          .toList(),
      'thermalState': null,
      'powerState': null,
      'timing':
          'End-to-end explicit readback; no presentation FPS or GPU timestamp claim.',
      'results': results,
    }),
  );
}
