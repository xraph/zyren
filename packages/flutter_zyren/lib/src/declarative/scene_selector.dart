import 'package:flutter/widgets.dart';
import '../controller/scene_controller.dart';
import 'scene_canvas.dart';

/// Rebuilds only when the selected value changes. Capture immutable values
/// (for example state.cameraPosition) instead of mutable object transforms.
/// You can use it in scene children, overlays, or with an explicit controller.
class SceneSelector<T> extends StatefulWidget {
  final SceneController? controller;
  final T Function(SceneState) select;
  final bool Function(T previous, T next)? equals;
  final Widget Function(BuildContext context, T value, Widget? child) builder;
  final Widget? child;
  const SceneSelector({
    super.key,
    this.controller,
    required this.select,
    this.equals,
    required this.builder,
    this.child,
  });
  @override
  State<SceneSelector<T>> createState() => _SceneSelectorState<T>();
}

class _SceneSelectorState<T> extends State<SceneSelector<T>> {
  SceneController? _controller;
  late T _value;
  void _bind() {
    final next = widget.controller ?? SceneScope.of(context);
    if (!identical(next, _controller)) {
      _controller?.state.removeListener(_changed);
      _controller = next;
      next.state.addListener(_changed);
    }
    _value = widget.select(next.state.value);
  }

  void _changed() {
    final next = widget.select(_controller!.state.value);
    if (widget.equals?.call(_value, next) ?? _value == next) return;
    setState(() => _value = next);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(SceneSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
  }

  @override
  void dispose() {
    _controller?.state.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _value, widget.child);
}
