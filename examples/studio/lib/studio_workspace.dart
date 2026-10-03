import 'package:flutter/material.dart';
import 'studio_theme.dart';

enum StudioDock { left, leftLower, right, rightLower, bottom }

class StudioPane {
  final String id, title;
  final IconData icon;
  final Widget child;
  final StudioDock? defaultDock;
  final bool initiallyOpen;
  final int order;
  const StudioPane(
    this.id,
    this.title,
    this.icon,
    this.child, {
    this.defaultDock,
    this.initiallyOpen = false,
    this.order = 0,
  });
}

/// Stable stack slots keep native surfaces and in-flight conversations alive.
class StudioWorkspace extends StatefulWidget {
  final Widget canvas;
  final List<StudioPane> panes;
  final String initialPane;
  final ValueChanged<String>? onActivePanel;
  const StudioWorkspace({
    super.key,
    required this.canvas,
    required this.panes,
    required this.initialPane,
    this.onActivePanel,
  });
  @override
  State<StudioWorkspace> createState() => _StudioWorkspaceState();
}

class _StudioWorkspaceState extends State<StudioWorkspace> {
  StudioDock _defaultDock(StudioPane p) =>
      p.defaultDock ??
      (p.id == 'inspector' && widget.initialPane == 'agent'
          ? StudioDock.rightLower
          : p.id == 'animation'
          ? StudioDock.bottom
          : p.id == 'scene' || p.id == 'assets'
          ? StudioDock.left
          : StudioDock.right);
  late final Map<String, StudioDock> _docks = {
    for (final p in widget.panes) p.id: _defaultDock(p),
  };
  late final List<String> _order = (List<StudioPane>.of(
    widget.panes,
  )..sort((a, b) => a.order.compareTo(b.order))).map((p) => p.id).toList();
  late final Map<StudioDock, String?> _active = _defaults();
  Map<StudioDock, String?> _defaults() {
    final result = {
      for (final dock in StudioDock.values) dock: null as String?,
    };
    for (final p in widget.panes) {
      if (p.id == 'scene' ||
          p.id == widget.initialPane ||
          (p.id == 'inspector' && widget.initialPane == 'agent') ||
          p.initiallyOpen) {
        result[_defaultDock(p)] ??= p.id;
      }
    }
    return result;
  }

  late String? _focusedPane = widget.initialPane;
  String? _narrowPane;
  bool _narrowInitialized = false, _dragging = false;
  double _left = 260, _right = 280, _bottom = 200;
  double _rightSplit = .5, _leftSplit = .5;
  bool _isRight(StudioDock? dock) =>
      dock == StudioDock.right || dock == StudioDock.rightLower;
  bool _isLeft(StudioDock? dock) =>
      dock == StudioDock.left || dock == StudioDock.leftLower;
  String _dockName(StudioDock dock) => switch (dock) {
    StudioDock.leftLower => 'lower left',
    StudioDock.rightLower => 'lower right',
    _ => dock.name,
  };
  void _focus(String id) {
    if (_focusedPane != id) setState(() => _focusedPane = id);
    widget.onActivePanel?.call(id);
  }

  @override
  void didUpdateWidget(covariant StudioWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.panes.map((pane) => pane.id).toSet();
    if (ids.length != widget.panes.length) {
      throw StateError('Duplicate workspace pane ID.');
    }
    _docks.removeWhere((id, _) => !ids.contains(id));
    _order.removeWhere((id) => !ids.contains(id));
    for (final pane in widget.panes) {
      if (!_docks.containsKey(pane.id)) {
        _docks[pane.id] = _defaultDock(pane);
        _order.add(pane.id);
        if (pane.initiallyOpen) _active[_docks[pane.id]!] ??= pane.id;
      }
    }
    for (final dock in StudioDock.values) {
      if (_active[dock] != null && !ids.contains(_active[dock])) {
        _active[dock] = null;
      }
    }
    if (_narrowPane != null && !ids.contains(_narrowPane)) _narrowPane = null;
  }

  void _move(String id, StudioDock dock, {String? before}) => setState(() {
    if (!_docks.containsKey(id) || before == id) return;
    _order.remove(id);
    final index = before == null ? -1 : _order.indexOf(before);
    _order.insert(index < 0 ? _order.length : index, id);
    _focusedPane = id;
    for (final side in StudioDock.values) {
      if (_active[side] == id) _active[side] = null;
    }
    _docks[id] = dock;
    _active[dock] = id;
    _narrowPane = id;
    widget.onActivePanel?.call(id);
  });

  Widget _header(StudioPane pane, bool narrow) => SizedBox(
    height: 32,
    child: Row(
      children: [
        const SizedBox(width: 12),
        Expanded(
          child: Draggable<String>(
            data: pane.id,
            onDragStarted: () => setState(() => _dragging = true),
            onDragEnd: (_) => setState(() => _dragging = false),
            feedback: Material(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(pane.title),
              ),
            ),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    pane.title,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        PopupMenuButton<StudioDock>(
          tooltip: 'Dock ${pane.title}',
          iconSize: 16,
          padding: EdgeInsets.zero,
          onSelected: (dock) => _move(pane.id, dock),
          itemBuilder: (_) => [
            for (final dock in StudioDock.values)
              PopupMenuItem(
                value: dock,
                child: Text('Move to ${_dockName(dock)}'),
              ),
          ],
          icon: Icon(Icons.more_vert, semanticLabel: 'Dock ${pane.title}'),
        ),
        IconButton(
          tooltip: 'Hide ${pane.title}',
          iconSize: 16,
          onPressed: () => setState(() {
            if (narrow) {
              _narrowPane = null;
            } else {
              _active[_docks[pane.id]!] = null;
            }
          }),
          icon: Icon(Icons.remove, semanticLabel: 'Hide ${pane.title}'),
        ),
      ],
    ),
  );

  Widget _railIcon(StudioPane pane) {
    final palette = StudioPalette.of(context);
    final open = _active[_docks[pane.id]] == pane.id;
    final focused = open && _focusedPane == pane.id;
    return Draggable<String>(
      key: ValueKey('rail-icon-${pane.id}'),
      data: pane.id,
      onDragStarted: () => setState(() => _dragging = true),
      onDragEnd: (_) => setState(() => _dragging = false),
      feedback: Material(
        color: palette.selection,
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(pane.icon, size: 18),
        ),
      ),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != pane.id,
        onAcceptWithDetails: (d) =>
            _move(d.data, _docks[pane.id]!, before: pane.id),
        builder: (_, candidates, _) => Container(
          decoration: BoxDecoration(
            border: candidates.isEmpty
                ? null
                : Border(top: BorderSide(color: palette.accent, width: 2)),
          ),
          margin: const EdgeInsets.symmetric(vertical: 3),
          child: IconButton(
            tooltip: pane.title,
            isSelected: open,
            style: IconButton.styleFrom(
              backgroundColor: focused
                  ? palette.accent
                  : open
                  ? palette.border
                  : Colors.transparent,
              foregroundColor: focused
                  ? (palette.dark ? Colors.black : Colors.white)
                  : palette.muted,
            ),
            onPressed: () => setState(() {
              final dock = _docks[pane.id]!;
              _active[dock] = open ? null : pane.id;
              _focusedPane = open ? null : pane.id;
              if (!open) widget.onActivePanel?.call(pane.id);
            }),
            icon: Icon(pane.icon, size: 17, semanticLabel: pane.title),
          ),
        ),
      ),
    );
  }

  Widget _railGroup(StudioDock dock) {
    final panes = {for (final pane in widget.panes) pane.id: pane};
    return DragTarget<String>(
      key: ValueKey('rail-drop-${dock.name}'),
      onAcceptWithDetails: (d) => _move(d.data, dock),
      builder: (_, candidates, _) => Container(
        width: 36,
        constraints: BoxConstraints(minHeight: _dragging ? 48 : 8),
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Colors.transparent
              : StudioPalette.of(context).selection,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in _order)
              if (_docks[id] == dock && panes[id] != null)
                _railIcon(panes[id]!),
          ],
        ),
      ),
    );
  }

  Widget _railDivider() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    child: Divider(
      color: StudioPalette.of(context).muted.withValues(alpha: .35),
    ),
  );

  void _resetLayout() => setState(() {
    for (final p in widget.panes) {
      _docks[p.id] = _defaultDock(p);
    }
    _order
      ..clear()
      ..addAll(
        (List<StudioPane>.of(
          widget.panes,
        )..sort((a, b) => a.order.compareTo(b.order))).map((p) => p.id),
      );
    _active
      ..clear()
      ..addAll(_defaults());
    _focusedPane = widget.initialPane;
    _rightSplit = _leftSplit = .5;
    _left = 260;
    _right = 280;
    _bottom = 200;
  });

  Widget _rail(bool narrow, {bool right = false}) => Material(
    color: StudioPalette.of(context).chrome,
    child: narrow
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in widget.panes)
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _narrowPane = _narrowPane == p.id ? null : p.id;
                      _focusedPane = p.id;
                    }),
                    style: TextButton.styleFrom(
                      backgroundColor: _narrowPane == p.id
                          ? StudioPalette.of(context).selection
                          : null,
                    ),
                    icon: Icon(p.icon, size: 16),
                    label: Text(p.title),
                  ),
              ],
            ),
          )
        : Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _railGroup(right ? StudioDock.right : StudioDock.left),
                      _railDivider(),
                      _railGroup(
                        right ? StudioDock.rightLower : StudioDock.leftLower,
                      ),
                    ],
                  ),
                ),
              ),
              if (!right)
                IconButton(
                  tooltip: 'Reset layout',
                  onPressed: _resetLayout,
                  icon: const Icon(Icons.more_horiz, size: 18),
                ),
              if (!right) ...[_railDivider(), _railGroup(StudioDock.bottom)],
            ],
          ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final narrow = c.maxWidth < 900;
      if (!_narrowInitialized) {
        _narrowPane = widget.initialPane;
        _narrowInitialized = true;
      }
      final rail = narrow ? 0.0 : 36.0;
      final gap = narrow ? 0.0 : 6.0;
      final top = narrow ? 32.0 : 4.0;
      final leftMinimum = {'scene', 'assets'}.contains(_active[StudioDock.left])
          ? 160.0
          : 260.0;
      final leftMaximum = c.maxWidth * .32;
      final left =
          !narrow &&
              (_active[StudioDock.left] != null ||
                  _active[StudioDock.leftLower] != null)
          ? _left.clamp(leftMinimum, leftMaximum)
          : 0.0;
      final right =
          !narrow &&
              (_active[StudioDock.right] != null ||
                  _active[StudioDock.rightLower] != null)
          ? _right.clamp(260.0, c.maxWidth * .37)
          : 0.0;
      final bottom = narrow
          ? (_narrowPane == null ? 0.0 : (c.maxHeight - top) * .48)
          : (_active[StudioDock.bottom] == null
                ? 0.0
                : _bottom.clamp(150.0, c.maxHeight * .6));
      final bodyHeight = c.maxHeight - top - bottom - gap;
      final splitRight =
          !narrow &&
          _active[StudioDock.right] != null &&
          _active[StudioDock.rightLower] != null;
      final rightTopHeight = (bodyHeight - gap) * _rightSplit;
      final splitLeft =
          !narrow &&
          _active[StudioDock.left] != null &&
          _active[StudioDock.leftLower] != null;
      final leftTopHeight = (bodyHeight - gap) * _leftSplit;
      Widget resize(bool vertical, void Function(DragUpdateDetails) update) =>
          MouseRegion(
            cursor: vertical
                ? SystemMouseCursors.resizeLeftRight
                : SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: vertical ? update : null,
              onVerticalDragUpdate: vertical ? null : update,
              child: Center(
                child: Container(
                  width: vertical ? 1 : null,
                  height: vertical ? null : 1,
                  color: StudioPalette.of(context).muted.withValues(alpha: .3),
                ),
              ),
            ),
          );
      return Stack(
        children: [
          Positioned(
            left: rail + left + (left > 0 ? gap : 0),
            top: top,
            right: rail + right + (right > 0 ? gap : 0),
            bottom: bottom + gap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(narrow ? 0 : 10),
              child: Material(
                color: StudioPalette.of(context).panel,
                child: widget.canvas,
              ),
            ),
          ),
          for (final pane in widget.panes)
            Builder(
              key: ValueKey('pane-${pane.id}'),
              builder: (_) {
                final dock = _docks[pane.id]!;
                final visible = narrow
                    ? _narrowPane == pane.id
                    : _active[dock] == pane.id;
                final isBottom = narrow || dock == StudioDock.bottom;
                return Positioned(
                  left: isBottom
                      ? rail
                      : _isLeft(dock)
                      ? rail
                      : c.maxWidth - rail - right,
                  top: isBottom
                      ? top + bodyHeight + gap
                      : splitRight && dock == StudioDock.rightLower
                      ? top + rightTopHeight + gap
                      : splitLeft && dock == StudioDock.leftLower
                      ? top + leftTopHeight + gap
                      : top,
                  width: isBottom
                      ? c.maxWidth - rail * 2
                      : _isLeft(dock)
                      ? (left == 0 ? 260 : left)
                      : (right == 0 ? 280 : right),
                  height: isBottom
                      ? (bottom == 0 ? 200 : bottom) - gap
                      : splitRight && _isRight(dock)
                      ? (dock == StudioDock.right
                            ? rightTopHeight
                            : bodyHeight - rightTopHeight - gap)
                      : splitLeft && _isLeft(dock)
                      ? (dock == StudioDock.left
                            ? leftTopHeight
                            : bodyHeight - leftTopHeight - gap)
                      : bodyHeight,
                  child: Offstage(
                    offstage: !visible,
                    child: TickerMode(
                      enabled: visible,
                      child: Material(
                        borderRadius: BorderRadius.circular(narrow ? 0 : 10),
                        clipBehavior: Clip.antiAlias,
                        color: Theme.of(context).colorScheme.surface,
                        child: Column(
                          children: [
                            _header(pane, narrow),
                            const Divider(height: 1),
                            Expanded(
                              child: Focus(
                                onFocusChange: (hasFocus) {
                                  if (hasFocus) _focus(pane.id);
                                },
                                child: Listener(
                                  onPointerDown: (_) => _focus(pane.id),
                                  child: pane.child,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          if (splitLeft)
            Positioned(
              key: const ValueKey('resize-left-split'),
              left: rail,
              top: top + leftTopHeight,
              width: left,
              height: gap,
              child: resize(
                false,
                (d) => setState(
                  () => _leftSplit =
                      (_leftSplit + d.delta.dy / (bodyHeight - gap)).clamp(
                        .3,
                        .7,
                      ),
                ),
              ),
            ),
          if (splitRight)
            Positioned(
              key: const ValueKey('resize-right-split'),
              right: rail,
              top: top + rightTopHeight,
              width: right,
              height: gap,
              child: resize(
                false,
                (d) => setState(
                  () => _rightSplit =
                      (_rightSplit + d.delta.dy / (bodyHeight - gap)).clamp(
                        .3,
                        .7,
                      ),
                ),
              ),
            ),
          if (!narrow && left > 0)
            Positioned(
              key: const ValueKey('resize-left'),
              left: rail + left,
              top: top,
              bottom: bottom,
              width: 6,
              child: resize(
                true,
                (d) => setState(
                  () => _left = (left + d.delta.dx).clamp(
                    leftMinimum,
                    leftMaximum,
                  ),
                ),
              ),
            ),
          if (!narrow && right > 0)
            Positioned(
              right: rail + right,
              top: top,
              bottom: bottom,
              width: 6,
              child: resize(
                true,
                (d) => setState(
                  () => _right = (right - d.delta.dx).clamp(
                    260,
                    c.maxWidth * .37,
                  ),
                ),
              ),
            ),
          if (!narrow && bottom > 0)
            Positioned(
              left: rail,
              right: rail,
              bottom: bottom,
              height: 6,
              child: resize(
                false,
                (d) => setState(
                  () => _bottom = (bottom - d.delta.dy).clamp(
                    150,
                    c.maxHeight * .6,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            top: 0,
            width: narrow ? c.maxWidth : rail,
            height: narrow ? top : c.maxHeight,
            child: _rail(narrow),
          ),
          if (!narrow)
            Positioned(
              right: 0,
              top: 0,
              width: rail,
              height: c.maxHeight,
              child: _rail(false, right: true),
            ),
          if (!narrow && _dragging)
            for (final dock in StudioDock.values)
              Positioned(
                key: ValueKey('edge-drop-${dock.name}'),
                left: _isRight(dock) ? null : rail,
                right: _isLeft(dock) ? null : rail,
                top: dock == StudioDock.bottom
                    ? null
                    : (dock == StudioDock.leftLower ||
                          dock == StudioDock.rightLower)
                    ? top + bodyHeight / 2
                    : top,
                bottom: dock == StudioDock.bottom ? 0 : null,
                width: dock == StudioDock.bottom ? null : 22,
                height: dock == StudioDock.bottom ? 22 : bodyHeight / 2,
                child: DragTarget<String>(
                  onAcceptWithDetails: (d) => _move(d.data, dock),
                  builder: (_, candidates, _) => ColoredBox(
                    color: candidates.isEmpty
                        ? Colors.transparent
                        : StudioPalette.of(
                            context,
                          ).accent.withValues(alpha: .25),
                  ),
                ),
              ),
        ],
      );
    },
  );
}
