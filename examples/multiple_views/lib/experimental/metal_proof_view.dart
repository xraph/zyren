import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/surfaces.dart';

const metalProofChannel = MethodChannel('gpu3d/metal-proof');

Future<void> connectMetalProof() => metalProofChannel.invokeMethod<void>(
  'connect',
  {'runtime': NativeSurfaces().runtimeToken},
);

Future<Map<Object?, Object?>> metalProofDiagnostics() async =>
    (await metalProofChannel.invokeMapMethod<Object?, Object?>('diagnostics'))!;

/// Static scene fixture for qualifying native view ownership and composition.
/// This isn't the SceneView API; updates, input and plugins still need an adapter.
class MetalProofView extends StatefulWidget {
  final Map<String, String> packets;
  final ValueChanged<int>? onCreated;
  const MetalProofView({super.key, required this.packets, this.onCreated});
  @override
  State<MetalProofView> createState() => _MetalProofViewState();
}

class _MetalProofViewState extends State<MetalProofView>
    with WidgetsBindingObserver {
  int? _view;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final view = _view;
    if (view != null) {
      unawaited(
        metalProofChannel.invokeMethod<void>('suspend', {
          'view': view,
          'suspended':
              state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden ||
              state == AppLifecycleState.detached ||
              (!Platform.isMacOS && state == AppLifecycleState.inactive),
        }),
      );
    }
  }

  void _created(int view) {
    if (!mounted) {
      unawaited(_close(view));
      return;
    }
    _view = view;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) didChangeAppLifecycleState(state);
    widget.onCreated?.call(view);
  }

  Future<void> _close(int view) =>
      metalProofChannel.invokeMethod<void>('close', {'view': view});
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final view = _view;
    if (view != null) unawaited(_close(view));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Platform.isMacOS
      ? AppKitView(
          viewType: 'gpu3d/metal-proof',
          creationParams: widget.packets,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _created,
        )
      : UiKitView(
          viewType: 'gpu3d/metal-proof',
          creationParams: widget.packets,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _created,
        );
}

Map<String, String> cornerPackets() {
  final scene = Scene()..background = const Color3(0, 0, 0);
  void quad(double left, double bottom, double right, double top, int rgb) {
    scene.add(
      Mesh(
        BufferGeometry(
          positions: [
            left,
            bottom,
            .4,
            right,
            bottom,
            .4,
            right,
            top,
            .4,
            left,
            top,
            .4,
          ],
          normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: [0, 1, 2, 0, 2, 3],
        ),
        UnlitMaterial(color: Color3.hex(rgb)),
      ),
    );
  }

  quad(-1, 0, 0, 1, 0xff0000);
  quad(0, 0, 1, 1, 0x00ff00);
  quad(-1, -1, 0, 0, 0x0000ff);
  quad(0, -1, 1, 0, 0xffffff);
  // A frontmost gray patch detects accidental linear/sRGB conversion.
  final patch = Mesh(
    BoxGeometry(width: .4, height: .4, depth: .01),
    UnlitMaterial(color: Color3.hex(0x808080)),
  )..position = const Vec3(0, 0, .2);
  scene.add(patch);
  final frame = FrameSubmission.capture(
    scene: scene,
    camera: _ClipCamera(),
    size: PhysicalSize(64, 64),
  );
  final initial = frame.toNativePacket();
  final uploaded = {
    for (final geometry in initial['geometries'] as List)
      (geometry as Map)['id'] as int,
  };
  return {
    'initial': jsonEncode(initial),
    'steady': jsonEncode(frame.toNativePacket(uploaded: uploaded)),
  };
}

class _ClipCamera extends PerspectiveCamera {
  _ClipCamera() : super(position: Vec3.zero, target: const Vec3(0, 0, -1));
  @override
  Mat4 viewProjection(double aspect) => Mat4.identity();
}
