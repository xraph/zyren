import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

void main() => runApp(const MaterialApp(home: PresentationBenchmark()));

class _Inspection extends ScenePlugin {
  @override
  String get id => 'benchmark-inspection';
  PluginContext? context;
  @override
  void attach(PluginContext context) => this.context = context;
}

class PresentationBenchmark extends StatefulWidget {
  const PresentationBenchmark({super.key});
  @override
  State<PresentationBenchmark> createState() => _PresentationBenchmarkState();
}

class _PresentationBenchmarkState extends State<PresentationBenchmark> {
  late final SceneController controller;
  late final StreamSubscription<PresentationSample> subscription;
  late final Registration update;
  final probe = _Inspection();
  final intervals = <int>[];
  var count = 0, readbackBytes = 0;
  var finished = false;
  String? report;
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
      camera: PerspectiveCamera(position: const Vec3(0, 0, 3)),
    )..use(probe);
    final plane = PlaneGeometry(width: 4, height: 3);
    final geometry = BufferGeometry.fromAttributes(
      attributes: {
        ...plane.attributes,
        VertexSemantic.tangent: VertexAttribute(
          Float32List.fromList([
            for (var i = 0; i < plane.vertexCount; i++) ...[1, 0, 0, 1],
          ]),
          format: VertexFormat.float32x4,
        ),
      },
      indices: plane.indices,
    );
    controller.scene
      ..background = const Color3(0, 0, 0)
      ..add(
        Mesh(
          geometry,
          PhysicalMaterial(
            baseColor: const Color3(.6, .2, .05),
            roughness: .35,
            anisotropy: .7,
            iridescence: .8,
            iridescenceThicknessMaximum: 350,
            clearcoat: .4,
            clearcoatRoughness: .2,
            sheenColor: const Color3(.1, .02, .01),
            sheenRoughness: .4,
          ),
        ),
      )
      ..add(
        RectAreaLight(width: 4, height: 1.3, intensity: 2)
          ..position = const Vec3(.4, -.3, 2),
      );
    update = controller.onUpdate((_) {});
    subscription = controller.presentations.listen((sample) {
      if (finished) return;
      count++;
      readbackBytes += sample.frame.readbackBytes;
      if (count > 120 && sample.interval != null) {
        intervals.add(sample.interval!.inMicroseconds);
      }
      if (intervals.length == 120) {
        finished = true;
        update.dispose();
        unawaited(_finish(sample));
      }
    });
  }

  Future<void> _finish(PresentationSample last) async {
    try {
      final info = await controller.ready;
      final gpu = await probe.context!.inspectGpu();
      await subscription.cancel();
      controller.dispose();
      if (mounted) setState(() {});
      await controller.whenDisposed;
      final ownership = await MethodChannel(
        Platform.isAndroid ? 'zyren/android-surfaces' : 'zyren/scene-views',
      ).invokeMapMethod<Object?, Object?>('diagnostics');
      final sorted = [...intervals]..sort();
      final result = {
        'fixture': 'physical-area-presentation',
        'backend': info.backend,
        'adapter': info.adapterName,
        'os': Platform.operatingSystemVersion,
        'size': [last.frame.physicalSize.width, last.frame.physicalSize.height],
        'measurement': 'presenterAcceptance',
        'warmupFrames': 120,
        'intervalMicros': intervals,
        'medianMicros': sorted[sorted.length ~/ 2],
        'p95Micros': sorted[(sorted.length * .95).ceil() - 1],
        'pixelReadbackBytes': readbackBytes,
        'lastGpuTimeNs': gpu?.lastSubmissionGpuTimeNs,
        'gpuTimeSource': gpu?.gpuTimeSource,
        'ownershipAfterDispose': ownership,
      };
      debugPrint(jsonEncode(result));
      if (mounted) {
        setState(
          () => report =
              '${result['medianMicros']} µs median · ${result['p95Micros']} µs p95 · $readbackBytes readback bytes',
        );
      }
    } catch (error, stack) {
      debugPrint('Presentation benchmark failed: $error\n$stack');
      controller.dispose();
      if (mounted) setState(() => report = 'Benchmark failed: $error');
    }
  }

  @override
  void dispose() {
    update.dispose();
    unawaited(subscription.cancel());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Native presentation pacing')),
    body: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            report ??
                '120 warmup frames, then 120 presentation intervals. Results print to the console.',
          ),
          const SizedBox(height: 8),
          if (!finished)
            SizedBox(
              width: 512,
              height: 384,
              child: SceneView(
                controller: controller,
                resolutionScale: 1 / View.of(context).devicePixelRatio,
              ),
            ),
        ],
      ),
    ),
  );
}
