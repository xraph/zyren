library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
export 'package:zyren_interaction/zyren_interaction.dart';

/// A non-interactive label. Use a surface when the child accepts input.
final class SceneLabel {
  final Object id;
  final SceneAnchor anchor;
  final Widget child;
  final Offset offset;
  const SceneLabel({
    required this.id,
    required this.anchor,
    required this.child,
    this.offset = const Offset(0, -24),
  });
}

/// A screen overlay projected from a scene anchor, with ordinary Flutter text,
/// semantics and focus. This allocates no native texture or render resource.
final class SceneWidgetSurface {
  final Object id;
  final SceneAnchor anchor;
  final Widget child;
  final Size size;
  final Offset offset;
  const SceneWidgetSurface({
    required this.id,
    required this.anchor,
    required this.child,
    this.size = const Size(200, 64),
    this.offset = const Offset(0, 36),
  });
}

/// Wrap the native SceneView in this widget. It borrows the controller and router.
/// Scene and camera updates reproject overlays; hidden/detached anchors unmount
/// their surfaces, releasing focus and cancelling active scene gestures.
class SceneInteractionOverlay extends StatefulWidget {
  final SceneController controller;
  final SceneInteractionRouter router;
  final Widget child;
  final List<SceneLabel> labels;
  final List<SceneWidgetSurface> surfaces;
  const SceneInteractionOverlay({
    super.key,
    required this.controller,
    required this.router,
    required this.child,
    this.labels = const [],
    this.surfaces = const [],
  });
  @override
  State<SceneInteractionOverlay> createState() =>
      _SceneInteractionOverlayState();
}

class _SceneInteractionOverlayState extends State<SceneInteractionOverlay> {
  final _subscriptions = <StreamSubscription<Object?>>[];
  late SceneAnchorProjector _projector;
  ViewportMetrics _viewport = const ViewportMetrics(0, 0);
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    if (!identical(widget.router.scene, widget.controller.scene)) {
      throw ArgumentError('Overlay and controller must share a scene.');
    }
    _projector = SceneAnchorProjector(
      scene: widget.router.scene,
      camera: () => widget.controller.camera,
      viewport: () => _viewport,
    );
    _subscriptions.addAll([
      widget.controller.presentations.listen((_) => _refresh()),
      widget.router.scene.changes.listen((_) => _refresh()),
      widget.router.focus.changes.listen((_) => _refresh()),
    ]);
  }

  void _unbind() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _projector.dispose();
  }

  @override
  void didUpdateWidget(SceneInteractionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.router != widget.router) {
      _unbind();
      _bind();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _viewport = ViewportMetrics(
        constraints.maxWidth,
        constraints.maxHeight,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
      final ids = <Object>{};
      final children = <Widget>[Positioned.fill(child: widget.child)];
      for (final target in widget.router.focus.targets) {
        final projection = _projector.project(SceneAnchor(target.object));
        if (!projection.visible) continue;
        final point = projection.point!;
        children.add(
          Positioned(
            left: point.x - 24,
            top: point.y - 24,
            width: 48,
            height: 48,
            child: Semantics(
              key: ValueKey(('scene-semantics', target.object.id)),
              identifier: 'scene-object-${target.object.id}',
              container: true,
              label: target.label,
              focusable: true,
              focused: identical(
                widget.router.focus.focusedObject,
                target.object,
              ),
              sortKey: OrdinalSortKey(target.order, name: 'scene-objects'),
              button: target.onActivate != null,
              onTap: target.onActivate == null
                  ? null
                  : () => widget.router.focus.activate(target.object),
              onDidGainAccessibilityFocus: () =>
                  widget.router.focus.request(target.object),
              onDidLoseAccessibilityFocus: () {
                if (identical(widget.router.focus.focusedObject, target.object)) {
                  widget.router.focus.blur();
                }
              },
              child: const IgnorePointer(child: SizedBox.expand()),
            ),
          ),
        );
      }
      for (final label in widget.labels) {
        if (!ids.add(label.id)) {
          throw ArgumentError('Overlay IDs must be unique.');
        }
        final projection = _projector.project(label.anchor);
        if (!projection.visible) continue;
        children.add(
          Positioned(
            left: projection.point!.x + label.offset.dx,
            top: projection.point!.y + label.offset.dy,
            child: FractionalTranslation(
              translation: const Offset(-.5, -.5),
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: KeyedSubtree(
                    key: ValueKey(label.id),
                    child: label.child,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      for (final surface in widget.surfaces) {
        if (!ids.add(surface.id)) {
          throw ArgumentError('Overlay IDs must be unique.');
        }
        if (!surface.size.width.isFinite ||
            !surface.size.height.isFinite ||
            surface.size.width <= 0 ||
            surface.size.height <= 0) {
          throw ArgumentError(
            'Surface dimensions must be finite and positive.',
          );
        }
        final projection = _projector.project(surface.anchor);
        if (!projection.visible) continue;
        final width = surface.size.width.clamp(0.0, constraints.maxWidth);
        final height = surface.size.height.clamp(0.0, constraints.maxHeight);
        children.add(
          Positioned(
            left: (projection.point!.x + surface.offset.dx - width / 2).clamp(
              0.0,
              constraints.maxWidth - width,
            ),
            top: (projection.point!.y + surface.offset.dy).clamp(
              0.0,
              constraints.maxHeight - height,
            ),
            width: width,
            height: height,
            child: _Surface(
              key: ValueKey(surface.id),
              input: widget.controller.input,
              focus: widget.router.focus,
              child: surface.child,
            ),
          ),
        );
      }
      return Stack(clipBehavior: Clip.hardEdge, children: children);
    },
  );
}

class _Surface extends StatefulWidget {
  final InputSource input;
  final SceneObjectFocus focus;
  final Widget child;
  const _Surface({
    super.key,
    required this.input,
    required this.focus,
    required this.child,
  });
  @override
  State<_Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<_Surface> {
  final _focus = FocusScopeNode(debugLabel: 'Scene widget surface');
  final _pointers = <int>{};
  Registration? _block;
  void _sync() {
    if (_pointers.isNotEmpty || _focus.hasFocus) {
      widget.focus.blur();
      _block ??= InputRouter.forSource(widget.input).block();
    } else {
      _block?.dispose();
      _block = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_sync);
  }

  @override
  void didUpdateWidget(_Surface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.input != widget.input) {
      _block?.dispose();
      _block = null;
      _pointers.clear();
      _sync();
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_sync);
    _block?.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    node: _focus,
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _pointers.add(event.pointer);
        _sync();
      },
      onPointerUp: (event) {
        _pointers.remove(event.pointer);
        _sync();
      },
      onPointerCancel: (event) {
        _pointers.remove(event.pointer);
        _sync();
      },
      child: widget.child,
    ),
  );
}
