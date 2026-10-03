import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_pointclouds/native.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/streaming.dart';
import 'package:zyren_splats/zyren_splats.dart';
import 'package:zyren_splats/streaming.dart';

void main() => runApp(const RealityCaptureLab());

class RealityCaptureLab extends StatelessWidget {
  const RealityCaptureLab({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const CaptureWorkbench(),
  );
}

class CaptureWorkbench extends StatefulWidget {
  const CaptureWorkbench({super.key});
  @override
  CaptureWorkbenchState createState() => CaptureWorkbenchState();
}

class CaptureWorkbenchState extends State<CaptureWorkbench> {
  SceneController? viewport;
  PointCloudStreamPlugin? points;
  GaussianStreamPlugin? splats;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? frameStats;
  String? error, backend;
  final imported = <String, PointCloudData>{};
  final _disposed = Completer<void>();
  Future<void> get whenDisposed => _disposed.future;
  bool ready = false, filtered = false, clipped = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      for (final name in [
        'survey.las',
        'survey.laz',
        'survey14.laz',
        'scans.e57',
      ]) {
        final bytes = (await rootBundle.load(
          'assets/$name',
        )).buffer.asUint8List();
        imported[name] = await const NativePointCloudLoader(
          sourceVersion: 'fixture-v1',
        ).parse(bytes, sourceUri: Uri.parse('asset:$name'));
      }
      if (!mounted) return;
      final data = PointCloudData(
        sourceUri: Uri.parse('memory:classification-grid'),
        sourceVersion: 'v1',
        points: [
          for (var y = 0; y < 16; y++)
            for (var x = 0; x < 16; x++) Vec3(x * .055 - .9, y * .055 - .4, 0),
        ],
        classifications: [
          for (var y = 0; y < 16; y++)
            for (var x = 0; x < 16; x++) x % 2 == 0 ? 2 : 7,
        ],
      );
      final tree = PointCloudOctree.fromData(data, samplesPerChunk: 16);
      points = PointCloudStreamPlugin(
        closeStreamOnDetach: false,
        stream: SpatialStreamer(root: tree.root, loader: tree.load),
        material: PointsMaterial(size: 4, color: const Color3(.25, .8, 1)),
      );
      final gaussians = GaussianCloudData(
        sourceUri: Uri.parse('memory:Gaussian-grid'),
        sourceVersion: 'v1',
        splats: [
          for (var y = 0; y < 6; y++)
            for (var x = 0; x < 6; x++)
              GaussianSplat(
                mean: Vec3(x * .12 + .15, y * .12 - .3, 0),
                covariance: GaussianCovariance(xx: .004, yy: .002, zz: .001),
                color: Color3(1, .15 + y * .1, .06),
                opacity: .8,
              ),
        ],
      );
      final gaussianTree = GaussianOctree.fromData(
        gaussians,
        samplesPerChunk: 4,
      );
      splats = GaussianStreamPlugin(
        closeStreamOnDetach: false,
        stream: SpatialStreamer(
          root: gaussianTree.root,
          loader: gaussianTree.load,
          budget: const SpatialStreamBudget(maxGpuBytes: 184 * 128),
        ),
      );
      final scene = Scene()..background = const Color3(.018, .023, .04);
      scene.add(
        Mesh(
          PlaneGeometry(width: .12, height: .9),
          UnlitMaterial(color: const Color3(.2, .5, .2)),
        )..position = const Vec3(.45, 0, .15),
      );
      final controller = SceneController(
        scene: scene,
        camera: PerspectiveCamera(
          position: const Vec3(0, 0, 2.5),
          near: .05,
          far: 100,
        ),
        runtime: Platform.isAndroid
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
          recovery: RecoveryPolicy.automaticOnce,
        ),
      );
      controller.use(points!);
      controller.use(splats!);
      subscription = controller.frameStats.listen((value) {
        if (mounted) setState(() => frameStats = value);
      });
      viewport = controller;
      setState(() {});
      final info = await controller.ready;
      if (mounted) {
        setState(() {
          ready = true;
          backend = info.backend;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void filter() {
    setState(() => filtered = !filtered);
    points!.filter = PointCloudFilter(classifications: filtered ? {2} : null);
  }

  void clip() {
    setState(() => clipped = !clipped);
    viewport!.scene.clippingPlanes = clipped
        ? [ClippingPlane(normal: const Vec3(1, 0, 0))]
        : [];
  }

  @override
  void dispose() {
    viewport?.dispose();
    unawaited(
      _close().then(_disposed.complete, onError: _disposed.completeError),
    );
    super.dispose();
  }

  Future<void> _close() async {
    await subscription?.cancel();
    await viewport?.whenDisposed;
    await points?.stream.close();
    await splats?.stream.close();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reality capture'), toolbarHeight: 48),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${imported.length}/4 native imports'),
                Text(ready ? 'Native view ready' : 'Loading'),
                FilledButton.tonal(
                  onPressed: ready ? filter : null,
                  child: Text(filtered ? 'Show all classes' : 'Ground only'),
                ),
                FilledButton.tonal(
                  onPressed: ready ? clip : null,
                  child: Text(clipped ? 'Clear section' : 'Section'),
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          Expanded(
            child: viewport == null
                ? const Center(child: CircularProgressIndicator())
                : Semantics(
                    label: 'Native point and Gaussian viewport',
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final aspect =
                            constraints.maxWidth / constraints.maxHeight;
                        final camera = viewport!.camera as PerspectiveCamera;
                        camera.position = Vec3(
                          0,
                          0,
                          math.max(
                            2.5,
                            1.1 / (math.tan(camera.fieldOfView / 2) * aspect),
                          ),
                        );
                        return SceneView(controller: viewport!);
                      },
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Points ${points?.stream.stats.visibleChunks ?? 0} chunks · Gaussians ${splats?.stream.stats.visibleChunks ?? 0} chunks · Readback ${frameStats?.readbackBytes ?? 0} B',
            ),
          ),
        ],
      ),
    ),
  );
}
