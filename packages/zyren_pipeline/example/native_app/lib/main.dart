import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_pipeline/agents.dart';
import 'package:zyren_pipeline/io.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const PipelineLab(),
  ),
);

class PipelineLab extends StatefulWidget {
  const PipelineLab({super.key});
  @override
  State<PipelineLab> createState() => PipelineLabState();
}

class PipelineLabState extends State<PipelineLab> {
  final scene = Scene()..background = Color3.hex(0x16242c);
  late final SceneController controller;
  final runtime = PipelineRuntime(
    cache: PipelineCache(),
    services: const AssetServices(),
  );
  final registry = AgentRegistry(grantedScopes: {'pipeline.cache.write'});
  late final PipelineAgentProvider pipeline;
  late final AgentViewportProvider viewport;
  late final Registration attachment;
  final disk = FilePipelineCache(
    directory: Directory('${Directory.systemTemp.path}/zyren-pipeline-lab'),
  );
  PipelineBundle? fixture, current;
  Mesh? mesh;
  bool busy = true, lod = true;
  String? error;
  String status = 'Opening local bundle';
  String target = 'pending';
  String? sourceIdentity;
  AgentPresentedFrame? presented;
  StreamSubscription<PresentationSample>? _frames;

  @override
  void initState() {
    super.initState();
    controller = SceneController(
      scene: scene,
      camera: PerspectiveCamera(position: const Vec3(0, 0, 3)),
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
    );
    pipeline = PipelineAgentProvider(runtime: runtime, instanceId: 'assets');
    attachment = pipeline.attach(registry);
    viewport = AgentViewportProvider(
      sceneId: 'pipeline-lab',
      documentId: 'prepared-grid',
      instanceId: 'main',
      scene: scene,
      camera: () => controller.camera,
      viewport: () => (controller.input as ViewportInputSource).viewport,
      presentedFrame: () => presented,
      metadata: (object) => identical(object, mesh)
          ? AgentObjectMetadata(
              sourceId: sourceIdentity,
              owningPlugin: 'zyren.pipeline',
              provenance: {
                'bundleVersion': current?.version,
                'sourceId': lod ? 'mesh-lod' : 'original-mesh',
                'pixelVisibility': 'unknown',
              },
            )
          : null,
    );
    registry.register(viewport);
    _frames = controller.presentations.listen((sample) {
      presented = AgentPresentedFrame(
        id: '${sample.frame.frameId}',
        presentedAt: 'controller+${sample.elapsed.inMicroseconds}us',
      );
    });
    unawaited(_open());
  }

  Future<void> _open() => _work(() async {
    final bytes = await rootBundle.load('assets/fixture.zybundle');
    fixture = PipelineBundle.decode(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    if (await disk.get(fixture!.version) == null) {
      if (!await disk.put(fixture!, pin: true)) {
        throw StateError('Offline cache budget is full.');
      }
    }
    await _reload();
  });
  Future<void> _work(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      await action();
    } catch (e) {
      error = e is PipelineCacheCorruption
          ? 'The local bundle was corrupt. Restore it to continue.'
          : 'The bundle could not be loaded. Restore it and retry.';
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> _reload() async {
    final bundle = await disk.get(fixture!.version);
    if (bundle == null) {
      if (mesh != null) scene.remove(mesh!);
      mesh = null;
      current = null;
      status = 'Bundle is not cached';
      return;
    }
    current = bundle;
    runtime.cache.put(bundle);
    await _show();
    status = 'Loaded from disk';
  }

  Future<void> _show() async {
    final info = await controller.ready;
    if (!mounted) return;
    final data =
        jsonDecode(
              utf8.decode(
                current!.resource(lod ? 'mesh-lod' : 'original-mesh').bytes,
              ),
            )
            as Map;
    sourceIdentity = data['sourceId'] as String;
    Float32List floats(String key) => Float32List.fromList(
      (data[key] as List).map((v) => (v as num).toDouble()).toList(),
    );
    final geometry = BufferGeometry(
      positions: floats('positions'),
      normals: floats('normals'),
      uv0: floats('uv'),
      indices: (data['indices'] as List).cast<int>(),
    );
    final texture = await NativeTextureDecoder.forDevice(info.capabilities)
        .decode(
          current!.resource('texture').bytes,
          encoding: TextureEncoding.ktx2Basis,
        );
    if (!mounted) return;
    target = '${info.backend} · ${texture.descriptor.format.name}';
    if (mesh != null) scene.remove(mesh!);
    mesh = Mesh(
      geometry,
      UnlitMaterial(
        colorMap: TextureMap(image: TextureImage.fromData(texture)),
      ),
      name: 'Prepared grid',
    );
    scene.add(mesh!);
    controller.invalidate();
  }

  Future<void> reload() => _work(_reload);
  Future<void> restore() => _work(() async {
    if (!await disk.put(fixture!, pin: true)) throw StateError('Cache is full');
    await _reload();
  });
  Future<void> toggleLod() => _work(() async {
    lod = !lod;
    await _show();
  });
  Future<void> evict() => _work(() async {
    final result = await registry.call(
      providerId: pipeline.id,
      instanceId: pipeline.instanceId,
      tool: 'invalidate-source',
      arguments: {'sourceId': 'original-mesh'},
      expectedRevision: pipeline.revision,
      idempotencyKey: 'evict-${pipeline.revision}',
    );
    if (result.status != AgentStatus.ok) {
      throw StateError('Invalidation failed');
    }
    await disk.invalidateVersion(fixture!.version);
    status = 'Cache evicted; current view retained';
  });
  @override
  void dispose() {
    unawaited(_frames?.cancel());
    attachment.dispose();
    registry.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pipeline Lab'), toolbarHeight: 48),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  mesh == null
                      ? status
                      : '${mesh!.geometry.capture().primitiveCount} triangles · $status',
                ),
                OutlinedButton(
                  onPressed: busy || current == null ? null : toggleLod,
                  child: Text(lod ? 'Show original' : 'Show LOD'),
                ),
                OutlinedButton(
                  onPressed: busy || fixture == null ? null : reload,
                  child: const Text('Reload'),
                ),
                OutlinedButton(
                  onPressed: busy || fixture == null ? null : evict,
                  child: const Text('Evict cache'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(target, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: SceneView(
                    controller: controller,
                    loadingBuilder: (_) => const ZeroState(
                      title: 'Starting native renderer',
                      message: 'Preparing the device.',
                    ),
                    errorBuilder: (_, issue, retry) => ZeroState(
                      title: 'Renderer unavailable',
                      message: issue.message,
                      actionLabel: 'Retry',
                      onAction: retry,
                    ),
                  ),
                ),
                if (error != null)
                  ZeroState(
                    title: 'Bundle unavailable',
                    message: error!,
                    actionLabel: 'Restore bundle',
                    onAction: busy ? null : restore,
                  )
                else if (!busy && mesh == null)
                  ZeroState(
                    title: 'No cached bundle',
                    message:
                        'Restore the prepared fixture to continue offline.',
                    actionLabel: 'Restore bundle',
                    onAction: restore,
                  ),
                if (busy)
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
