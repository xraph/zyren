import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_zyren/widgets.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren/zyren.dart' as z;
import 'package:zyren_xr/agents.dart';
import 'package:zyren_xr/flutter.dart';

void main() => runApp(const XrProbeApp());

class XrProbeApp extends StatelessWidget {
  final XrTransport transport;
  const XrProbeApp({
    super.key,
    this.transport = const MethodChannelXrTransport(),
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(useMaterial3: true, visualDensity: VisualDensity.compact),
    home: XrProbePage(transport: transport),
  );
}

class XrProbePage extends StatefulWidget {
  final XrTransport transport;
  const XrProbePage({super.key, required this.transport});
  @override
  State<XrProbePage> createState() => _XrProbePageState();
}

class _XrProbePageState extends State<XrProbePage> {
  XrSession? _session;
  XrSnapshot? _snapshot;
  XrCapabilities? _capabilities;
  XrAgentProvider? _provider;
  AgentRegistry? _registry;
  Timer? _timer, _renderTimer;
  XrPresentationController? _presentation;
  final _cube = z.Mesh(
    z.BoxGeometry(width: .1, height: .1, depth: .1),
    z.UnlitMaterial(color: const z.Color3(1, .45, .1)),
  )..position = const z.Vec3(0, 0, -.5);
  late final _scene = z.Scene()
    ..background = null
    ..backgroundOpacity = 0
    ..add(_cube);
  bool _busy = false, _polling = false;
  String? _error, _lastAction;
  int _command = 0;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    _capabilities = await XrSession.capabilities(widget.transport);
    if (!mounted) return;
    final session = _session ?? await XrSession.create(widget.transport);
    if (!mounted) {
      await session.dispose();
      return;
    }
    _session = session;
    await session.start();
    if (_capabilities!.cameraPresentation && _presentation == null) {
      final presenter = await XrPresentationController.create(
        session: session,
        transport: widget.transport,
      );
      if (!mounted || !identical(session, _session)) {
        await presenter.close();
        return;
      }
      setState(() => _presentation = presenter);
      _renderTimer = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _render(),
      );
    }
    if (!mounted) return;
    _registry ??= AgentRegistry(grantedScopes: {'xr.place'});
    if (_provider == null) {
      _provider = XrAgentProvider(
        instanceId: 'probe',
        commands: XrPlacementCommands(session),
        deviceCapabilities: _capabilities!,
        view: () {
          final media = MediaQuery.of(context);
          return XrViewBinding(
            sceneId: 'xr-probe',
            documentId: 'unsaved-probe',
            viewportId: 'session-inspector',
            cameraId: 'arkit-sensor',
            sceneRevision: 0,
            logicalRect: [0, 0, media.size.width, media.size.height],
            devicePixelRatio: media.devicePixelRatio,
            sceneFromSession: XrPose.identity(),
          );
        },
        allowPlacement: true,
      );
      _registry!.register(_provider!);
    }
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _poll(),
    );
    await _poll();
  }

  Future<void> _render() async {
    final presenter = _presentation;
    if (presenter == null ||
        presenter.isRendering ||
        _snapshot?.state != XrSessionState.running) {
      return;
    }
    try {
      final anchors = _snapshot?.frame?.anchors;
      if (anchors != null && anchors.isNotEmpty) {
        final pose = anchors.last.pose.matrix;
        _cube.position = z.Vec3(pose[12], pose[13], pose[14]);
      }
      await presenter.render(_scene);
    } on XrException catch (error) {
      if (error.code == 'frameDeferred' ||
          error.code == 'trackingUnavailable' ||
          error.code == 'busy') {
        return;
      }
      _renderTimer?.cancel();
      if (mounted) setState(() => _error = '$error');
    } catch (error) {
      _renderTimer?.cancel();
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _poll() async {
    final session = _session;
    if (_polling || session == null) return;
    _polling = true;
    try {
      final snapshot = await session.snapshot();
      if (mounted && identical(session, _session)) {
        setState(() => _snapshot = snapshot);
      }
    } catch (error) {
      if (mounted && identical(session, _session)) {
        setState(() => _error = '$error');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _placement({bool undo = false}) async {
    final provider = _provider!;
    final snapshot = await _session!.snapshot();
    final args = <String, Object?>{
      'sceneRevision': 0,
      'viewportId': 'session-inspector',
    };
    if (!undo) {
      final frame = snapshot.frame;
      if (frame == null) {
        throw const XrException('trackingUnavailable', 'No camera frame.');
      }
      final pose = frame.cameraPose.matrix.toList();
      // Half a metre along the sensor camera's forward axis.
      for (var row = 0; row < 3; row++) {
        pose[12 + row] -= pose[8 + row] * 0.5;
      }
      args.addAll({
        'transform': pose,
        'sessionRevision': snapshot.revision,
        'frameTimestamp': frame.timestamp,
      });
    }
    final result = await _registry!.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: undo ? 'undo_placement' : 'place_anchor',
      arguments: args,
      expectedRevision: provider.revision,
      idempotencyKey: 'probe-${_command++}',
    );
    if (!result.isSuccess) {
      throw StateError('${result.status.name}: ${result.message}');
    }
    if (mounted) {
      setState(
        () => _lastAction =
            '${undo ? 'Removed' : 'Placed'} ${result.affectedIds.join(', ')}',
      );
    }
    await _poll();
  }

  Future<void> _release() async {
    _timer?.cancel();
    _timer = null;
    _renderTimer?.cancel();
    _renderTimer = null;
    final presentation = _presentation;
    _presentation = null;
    await presentation?.close();
    presentation?.dispose();
    _registry?.dispose();
    _registry = null;
    _provider?.dispose();
    _provider = null;
    final session = _session;
    _session = null;
    _snapshot = null;
    await session?.dispose();
  }

  @override
  void dispose() {
    unawaited(
      _release().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final frame = snapshot?.frame;
    final running = snapshot?.state == XrSessionState.running;
    return Scaffold(
      appBar: AppBar(title: const Text('XR session probe'), toolbarHeight: 48),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ARKit camera and a 10 cm cube. Place an anchor to move the cube.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton(
                  onPressed: _busy || running ? null : () => _perform(_start),
                  child: const Text('Start'),
                ),
                OutlinedButton(
                  onPressed: _busy || _session == null
                      ? null
                      : () => _perform(() async {
                          await _session!.pause();
                          await _poll();
                        }),
                  child: const Text('Pause'),
                ),
                OutlinedButton(
                  onPressed: _busy || _session == null
                      ? null
                      : () => _perform(_release),
                  child: const Text('Release'),
                ),
                OutlinedButton(
                  onPressed: _busy || frame?.tracking != XrTrackingState.normal
                      ? null
                      : () => _perform(_placement),
                  child: const Text('Place anchor'),
                ),
                OutlinedButton(
                  onPressed: _busy || !(_provider?.commands.canUndo ?? false)
                      ? null
                      : () => _perform(() => _placement(undo: true)),
                  child: const Text('Undo'),
                ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_presentation != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                width: double.infinity,
                child: XrCameraView(controller: _presentation!),
              ),
              if (_presentation!.presentedCalibration case final calibration?)
                Text(
                  'Presented ${calibration.frameId} / ${calibration.pixelWidth} × ${calibration.pixelHeight} / revision ${calibration.revision}',
                ),
            ],
            if (_error != null)
              ZeroState(
                title: 'XR request failed',
                message: _error!,
                actionLabel: 'Release session',
                onAction: _busy ? null : () => _perform(_release),
              ),
            if (_error == null && snapshot?.failure != null)
              ZeroState(
                title: 'Native session failed',
                message: snapshot!.failure!.message,
                actionLabel: 'Release session',
                onAction: () => _perform(_release),
              ),
            if (_error == null && snapshot?.failure == null && frame == null)
              ZeroState(
                title: snapshot == null
                    ? 'Session not started'
                    : 'Session ${snapshot.state.name}',
                message: running
                    ? 'Waiting for the first ARKit frame.'
                    : 'Start on a physical ARKit device to inspect tracking. Accept camera access when prompted.',
                actionLabel: running ? null : 'Start session',
                onAction: _busy || running ? null : () => _perform(_start),
              ),
            if (frame != null) ...[
              const SizedBox(height: 8),
              Text(
                '${snapshot!.state.name} / ${frame.tracking.name}${frame.trackingReason == null ? '' : ' (${frame.trackingReason})'}',
              ),
              Text(
                'Frame ${frame.timestamp.toStringAsFixed(3)} s / age ${frame.ageAt(snapshot.nativeTimestamp).toStringAsFixed(3)} s',
              ),
              Text(
                'Camera xyz: ${frame.cameraPose.matrix.sublist(12, 15).map((v) => v.toStringAsFixed(3)).join(', ')} m',
              ),
              Text(
                'Anchors ${frame.anchors.length} / planes ${frame.planes.length} / omitted ${frame.omittedPlanes}',
              ),
              Text(
                'Depth hardware ${_capabilities?.sceneDepthHardware} / depth occlusion false',
              ),
              Text(
                'Agent tools ${_provider!.tools.length} / command revision ${_provider!.revision}',
              ),
              if (frame.light != null)
                Text(
                  'Ambient ${frame.light!.ambientIntensity.toStringAsFixed(0)} / ${frame.light!.colorTemperature.toStringAsFixed(0)} K',
                ),
            ],
            if (_lastAction != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(_lastAction!),
              ),
          ],
        ),
      ),
    );
  }
}
