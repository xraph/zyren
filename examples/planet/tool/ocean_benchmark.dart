import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_capture/zyren_capture.dart' show encodeCapturePng;
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:planet/ocean/scenes/coast_store.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/scenes/world.dart';

Future<void> main(List<String> args) => runOceanBenchmark(args);

/// Fixed simulation timestamps. Host readback timings do not establish display FPS.
Future<void> runOceanBenchmark(List<String> args) async {
  final options = <String, String>{};
  for (final arg in args) {
    final split = arg.indexOf('=');
    if (!arg.startsWith('--') || split < 3) {
      throw ArgumentError(
        'Use --output=DIR --frames=60 --width=1280 --height=720 --detail=balanced --scene=all --debug=color',
      );
    }
    options[arg.substring(2, split)] = arg.substring(split + 1);
  }
  final output = Directory(options['output'] ?? '/tmp/zyren-ocean-benchmark');
  final frames = int.parse(options['frames'] ?? '60');
  final width = int.parse(options['width'] ?? '1280');
  final height = int.parse(options['height'] ?? '720');
  if (frames < 2 ||
      frames > 1801 ||
      width < 1 ||
      width > 3840 ||
      height < 1 ||
      height > 2160) {
    throw ArgumentError(
      'Expected 2..1801 frames and dimensions within 3840x2160.',
    );
  }
  final detail = OceanLabDetail.values.byName(options['detail'] ?? 'balanced');
  final debug = OceanWaterDebug.values.byName(options['debug'] ?? 'color');
  final selected = options['scene'] ?? 'all';
  final definitionsFile = File.fromUri(
    Platform.script.resolve(
      Platform.script.path.contains('/tool/qualification/')
          ? '../../examples/planet/assets/ocean/scenes.json'
          : '../assets/ocean/scenes.json',
    ),
  );
  final definitions = OceanLabSceneDefinition.decode(
    await definitionsFile.readAsString(),
  ).where((s) => selected == 'all' || s.id == selected).toList();
  if (definitions.isEmpty) throw ArgumentError('Unknown scene: $selected');
  await output.create(recursive: true);
  final store = await Directory.systemTemp.createTemp('ocean-benchmark-coast-');
  final coast = await OceanLabCoast.open(store, allowFixtureGeneration: true);
  final backend = await NativeBackend.create();
  await backend.configureResourceBudget(768 * 1024 * 1024);
  final reports = <Map<String, Object?>>[];
  try {
    for (final definition in definitions) {
      stdout.writeln(
        'Rendering ${definition.id}, ${detail.name}, $width x $height',
      );
      final lab = OceanLabWorld(
        definition,
        coast,
        detail: detail,
        debug: debug,
      );
      final engine = await SceneEngine.create(
        scene: lab.scene,
        camera: lab.camera,
        backendFactory: () async => backend.createView(),
        plugins: lab.plugins,
      );
      final timings = <double>[],
          cpuBuild = <double>[],
          cpuSubmit = <double>[],
          gpu = <double>[],
          waves = <double>[];
      final captures = <String>[];
      Map<String, Object?>? diagnostic;
      try {
        if (definition.id == 'orbit') lab.setRoute(true);
        for (var index = 0; index < frames; index++) {
          final clock = Stopwatch()..start();
          final frame =
              await engine.renderFrame(
                    elapsed: Duration(
                      microseconds: (index * 1000000 / 60).round(),
                    ),
                    width: width,
                    height: height,
                  )
                  as ReadbackOutput;
          clock.stop();
          if (lab.simulationFailure != null) {
            throw StateError('${lab.simulationFailure}');
          }
          if (index >= 5) {
            timings.add(clock.elapsedMicroseconds / 1000);
            cpuBuild.add(frame.stats.cpuBuildTime.inMicroseconds / 1000);
            cpuSubmit.add(frame.stats.cpuSubmitTime.inMicroseconds / 1000);
            if (frame.stats.gpuTime case final time?) {
              gpu.add(time.inMicroseconds / 1000);
            }
            final d = lab.presentation!.controller!.diagnostics();
            waves.add(
              d.passes
                  .where((p) => p.name.startsWith('waves'))
                  .fold(
                    0.0,
                    (sum, p) =>
                        sum + (p.hostElapsed?.inMicroseconds ?? 0) / 1000,
                  ),
            );
          }
          if (index == 0 ||
              index == frames - 1 ||
              index == frames ~/ 2 ||
              options['motion'] == 'true') {
            final file =
                '${definition.id}-${debug.name}-${index.toString().padLeft(4, '0')}.png';
            await File(
              '${output.path}/$file',
            ).writeAsBytes(encodeCapturePng(frame.image));
            captures.add(file);
          }
        }
        final sampler = lab.host.registry.find(oceanSampler)!;
        final samples = await sampler.sampleBatch([
          for (final offset in [
            const Vec3(0, 0, 0),
            const Vec3(10, 0, 0),
            const Vec3(-10, 10, 0),
          ])
            OceanQuery(
              lab.host.worldFrame.toEcef(offset),
              lab.host.clock.instant,
            ),
        ], OceanQueryPolicy());
        diagnostic = lab.presentation!.controller!
            .diagnostics(
              patchCount: lab.presentation!.view!.patchCount,
              lastQuery: samples.first,
            )
            .toJson();
        final stats = await backend.resourceStats();
        reports.add({
          'scene': definition.id,
          'revision': definition.revision,
          'debug': debug.name,
          'detail': detail.name,
          'preset': null,
          'width': width,
          'height': height,
          'frames': frames,
          'warmupFrames': 5,
          'simulationHz': 60,
          'finalTick': lab.host.clock.tick,
          'wholeFrameHostReadbackMs': _percentiles(timings),
          'sceneBuildCpuMs': _percentiles(cpuBuild),
          'sceneSubmitCpuMs': _percentiles(cpuSubmit),
          'wholeFrameGpuMs': null,
          'renderSubmissionGpuMs': gpu.length == timings.length
              ? _percentiles(gpu)
              : null,
          'waveSubmissionHostMs': _percentiles(waves),
          'waterIncrementalCpuMs': null,
          'waterIncrementalGpuMs': null,
          'physicalGpuResidencyBytes': null,
          'registryPayloadBytes': stats.residentBytes,
          'nativeAllocations': stats.liveAllocations,
          'captures': captures,
          'diagnostics': diagnostic,
          'queries': [
            for (final sample in samples)
              {
                'available': sample.available,
                'failure': sample.failure?.toString(),
                'heightMetres': sample.height,
                'rootResidualMetres': sample.residual,
                'heightErrorBoundMetres': sample.accuracy?.heightErrorMetres,
                'normalErrorBoundRadians': sample.accuracy?.normalErrorRadians,
                'velocityErrorBoundMetresPerSecond':
                    sample.accuracy?.velocityErrorMetresPerSecond,
                'ageMicroseconds': sample.age?.inMicroseconds,
              },
          ],
        });
      } finally {
        await engine.dispose();
      }
      final allocations = (await backend.resourceStats()).liveAllocations;
      final graphs = (await backend.graphStats()).liveGraphs;
      reports.last['afterClose'] = {
        'allocations': allocations,
        'graphs': graphs,
      };
      if (allocations != 0 || graphs != 0) {
        throw StateError('Scene resources leaked.');
      }
      await File('${output.path}/report.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schema': 1,
          'platform': Platform.operatingSystem,
          'generatedAt': DateTime.now().toUtc().toIso8601String(),
          'timingScope':
              'Native offscreen readback. Host waits include GPU completion. Five warmup frames excluded.',
          'limitations': [
            'No isolated water timing or physical residency measurement.',
            'Queries bound the numerical model, not real-water agreement.',
            'Synthetic coast and all-water scenes. No geographic Earth dataset.',
          ],
          'scenes': reports,
        }),
      );
    }
  } finally {
    await backend.close();
    await coast.close();
    await store.delete(recursive: true);
  }
}

Map<String, double>? _percentiles(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  double at(double p) => sorted[((sorted.length - 1) * p).round()];
  return {'p50': at(.5), 'p95': at(.95), 'p99': at(.99)};
}
