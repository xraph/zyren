import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpu3d_native/surfaces.dart';

import 'experimental/metal_proof_view.dart' show cornerPackets;

const androidProofChannel = MethodChannel('gpu3d/android-proof');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await androidProofChannel.invokeMethod<void>('connect', {
    'runtime': NativeSurfaces().runtimeToken,
  });
  runApp(const MaterialApp(home: _Demo()));
}

class _Demo extends StatefulWidget {
  const _Demo();
  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  bool paused = false;
  bool compact = false;
  bool left = true;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Native Vulkan surfaces')),
    body: SafeArea(
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => setState(() => paused = !paused),
                child: Text(paused ? 'Resume' : 'Pause'),
              ),
              TextButton(
                onPressed: () => setState(() => compact = !compact),
                child: const Text('Resize'),
              ),
              TextButton(
                onPressed: () => setState(() => left = !left),
                child: Text(left ? 'Close first' : 'Open first'),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Red / green above blue / white. The center patch is sRGB gray.',
            ),
          ),
          if (left)
            SizedBox(
              height: compact ? 127 : 211,
              child: _Surface(key: const ValueKey('first'), paused: paused),
            ),
          SizedBox(
            height: compact ? 151 : 211,
            child: _Surface(key: const ValueKey('second'), paused: paused),
          ),
        ],
      ),
    ),
  );
}

class _Surface extends StatefulWidget {
  final bool paused;
  const _Surface({super.key, required this.paused});
  @override
  State<_Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<_Surface> with WidgetsBindingObserver {
  final packets = cornerPackets();
  bool uploaded = false;
  int? session;
  int? texture;
  int width = 1, height = 1, frames = 0;
  bool busy = false, background = false;
  String status = 'Creating native surface';
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(create());
  }

  Future<void> create() async {
    try {
      final value = (await androidProofChannel.invokeMapMethod<String, Object?>(
        'create',
      ))!;
      final id = value['session']! as int;
      if (!mounted) {
        await androidProofChannel.invokeMethod<void>('close', {'session': id});
        return;
      }
      setState(() {
        session = id;
        texture = value['texture']! as int;
      });
      await suspend();
      timer = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => unawaited(draw()),
      );
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    }
  }

  Future<void> suspend() async {
    final id = session;
    if (id == null) return;
    try {
      await androidProofChannel.invokeMethod<void>('suspend', {
        'session': id,
        'suspended': widget.paused || background,
      });
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    }
  }

  @override
  void didUpdateWidget(covariant _Surface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paused != oldWidget.paused) unawaited(suspend());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    background = state != AppLifecycleState.resumed;
    unawaited(suspend());
  }

  Future<void> draw() async {
    if (!mounted || busy || widget.paused || background || session == null) {
      return;
    }
    busy = true;
    try {
      final info = (await androidProofChannel
          .invokeMapMethod<String, Object?>('render', {
            'session': session,
            'width': width,
            'height': height,
            'scene': packets[uploaded ? 'steady' : 'initial'],
          }))!;
      if (info['applied'] == true) uploaded = true;
      if (info['presented'] == true) frames++;
      if (mounted && frames % 30 == 0) {
        setState(
          () => status =
              '${info['adapter']} · $frames frames · ${info['readbackBytes']} readback bytes',
        );
        debugPrint('Vulkan demo: $info');
      }
    } catch (error) {
      timer?.cancel();
      if (mounted) setState(() => status = '$error');
    } finally {
      busy = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final id = session;
    if (id != null) {
      unawaited(
        androidProofChannel
            .invokeMethod<void>('close', {'session': id})
            .catchError((Object error) {
              debugPrint('Vulkan cleanup: $error');
            }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final ratio = MediaQuery.devicePixelRatioOf(context);
            width = (constraints.maxWidth * ratio).round().clamp(1, 4096);
            height = (constraints.maxHeight * ratio).round().clamp(1, 4096);
            return texture == null
                ? const Center(child: CircularProgressIndicator())
                : Texture(textureId: texture!);
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(4),
        child: Text(status, maxLines: 2),
      ),
    ],
  );
}
