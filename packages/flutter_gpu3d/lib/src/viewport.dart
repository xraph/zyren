import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'native_renderer.dart';
import 'scene.dart';

typedef FrameCallback = void Function(Duration elapsed);

/// Displays a native GPU frame. The widget owns and disposes its renderer.
class SceneView extends StatefulWidget {
  final Scene scene;
  final PerspectiveCamera camera;
  final FrameCallback? onFrame;
  final void Function(Object error)? onError;
  final Widget Function(BuildContext context, Object error)? errorBuilder;
  final double pixelRatio;
  final int maxFramesPerSecond;
  const SceneView({
    super.key,
    required this.scene,
    required this.camera,
    this.onFrame,
    this.onError,
    this.errorBuilder,
    this.pixelRatio = 1,
    this.maxFramesPerSecond = 30,
  });
  @override
  State<SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<SceneView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  NativeRenderer? _renderer;
  ui.Image? _image;
  Object? _error;
  late final Ticker _ticker;
  Size _size = Size.zero;
  bool _busy = false;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final renderer = await NativeRenderer.create();
      if (!mounted) {
        await renderer.dispose();
        return;
      }
      _renderer = renderer;
      if (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _ticker.start();
      }
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!mounted) return;
    _ticker.stop();
    setState(() {
      _error = error;
    });
    widget.onError?.call(error);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _renderer != null &&
        _error == null) {
      _last = Duration.zero;
      if (!_ticker.isActive) _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    if (_busy || _size.isEmpty || _renderer == null) return;
    final fps = widget.maxFramesPerSecond.clamp(1, 120);
    if (elapsed - _last < Duration(microseconds: 1000000 ~/ fps)) return;
    _last = elapsed;
    _busy = true;
    unawaited(_draw(elapsed));
  }

  Future<void> _draw(Duration elapsed) async {
    ui.Image? next;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      if (!widget.pixelRatio.isFinite || widget.pixelRatio <= 0) {
        throw ArgumentError('pixelRatio must be positive.');
      }
      widget.onFrame?.call(elapsed);
      final ratio = math.min(
        widget.pixelRatio,
        4096 / math.max(_size.width, _size.height),
      );
      final frame = await _renderer!.render(
        widget.scene,
        widget.camera,
        width: math.max(1, (_size.width * ratio).round()),
        height: math.max(1, (_size.height * ratio).round()),
      );
      if (!mounted) return;
      buffer = await ui.ImmutableBuffer.fromUint8List(frame.pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: frame.width,
        height: frame.height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      next = (await codec.getNextFrame()).image;
      if (!mounted) {
        next.dispose();
        return;
      }
      final previous = _image;
      setState(() {
        _image = next;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previous?.dispose();
      });
    } catch (error) {
      _fail(error);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      _busy = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _image?.dispose();
    final renderer = _renderer;
    if (renderer != null) unawaited(renderer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
        return const Text('SceneView needs a bounded width and height.');
      }
      _size = constraints.biggest;
      if (_error != null) {
        return widget.errorBuilder?.call(context, _error!) ??
            Center(child: Text('Native rendering failed: $_error'));
      }
      return RawImage(
        image: _image,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.low,
      );
    },
  );
}
