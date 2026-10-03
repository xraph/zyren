import 'package:flutter/material.dart';
import 'studio_theme.dart';

enum StudioDock { left, right, rightLower, bottom }

class StudioPane {
  final String id, title;
  final IconData icon;
  final Widget child;
  const StudioPane(this.id, this.title, this.icon, this.child);
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
  late final Map<String, StudioDock> _docks = {
    for (final p in widget.panes)
      p.id: p.id == 'inspector' && widget.initialPane == 'agent'
          ? StudioDock.rightLower
          : p.id == 'animation'
          ? StudioDock.bottom
          : p.id == 'scene' || p.id == 'assets'
          ? StudioDock.left
          : StudioDock.right,
  };
  late final Map<StudioDock, String?> _active = {
    StudioDock.left: 'scene',
    StudioDock.right: widget.initialPane,
    StudioDock.rightLower:
        widget.initialPane == 'agent' &&
            widget.panes.any((p) => p.id == 'inspector')
        ? 'inspector'
        : null,
    StudioDock.bottom: null,
  };
  String? _narrowPane;
  bool _narrowInitialized = false;
  double _left = 260, _right = 280, _bottom = 200;
  double _rightSplit = .5;
  bool _isRight(StudioDock? dock) =>
      dock == StudioDock.right || dock == StudioDock.rightLower;

  @override
  void didUpdateWidget(covariant StudioWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.panes.map((pane) => pane.id).toSet();
    if (ids.length != widget.panes.length) {
      throw StateError('Duplicate workspace pane ID.');
    }
    _docks.removeWhere((id, _) => !ids.contains(id));
    for (final pane in widget.panes) {
      _docks.putIfAbsent(
        pane.id,
        () => pane.id == 'animation'
            ? StudioDock.bottom
            : pane.id == 'scene' || pane.id == 'assets'
            ? StudioDock.left
            : StudioDock.right,
      );
    }
    for (final dock in StudioDock.values) {
      if (_active[dock] != null && !ids.contains(_active[dock])) {
        _active[dock] = null;
      }
    }
    if (_narrowPane != null && !ids.contains(_narrowPane)) _narrowPane = null;
  }

  void _move(String id, StudioDock dock) => setState(() {
    for (final side in StudioDock.values) {
      if (_active[side] == id) _active[side] = null;
    }
    _docks[id] = dock;
    _active[dock] = id;
    _narrowPane = id;
  });

  Widget _header(StudioPane pane, bool narrow) => SizedBox(
    height: 32,
    child: Row(
      children: [
        const SizedBox(width: 12),
        Expanded(
          child: Draggable<String>(
            data: pane.id,
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
                child: Text(
                  dock == StudioDock.rightLower
                      ? 'Move to lower right'
                      : 'Move to ${dock.name}',
                ),
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

  Widget _rail(bool narrow, {bool right = false}) => Material(
    color: StudioPalette.of(context).chrome,
    child: narrow
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in widget.panes)
                  TextButton.icon(
                    onPressed: () => setState(
                      () => _narrowPane = _narrowPane == p.id ? null : p.id,
                    ),
                    icon: Icon(p.icon, size: 16),
                    label: Text(p.title),
                  ),
              ],
            ),
          )
        : Column(
            children: [
              for (final p in widget.panes.where(
                (p) => right ? _isRight(_docks[p.id]) : !_isRight(_docks[p.id]),
              ))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: IconButton(
                    tooltip: p.title,
                    style: IconButton.styleFrom(
                      backgroundColor: _active[_docks[p.id]] == p.id
                          ? StudioPalette.of(context).border
                          : Colors.transparent,
                    ),
                    isSelected: _active[_docks[p.id]] == p.id,
                    onPressed: () => setState(() {
                      final side = _docks[p.id]!;
                      _active[side] = _active[side] == p.id ? null : p.id;
                    }),
                    icon: Icon(p.icon, size: 17, semanticLabel: p.title),
                  ),
                ),
              const Spacer(),
              if (!right)
                IconButton(
                  tooltip: 'Reset layout',
                  icon: const Icon(Icons.view_quilt_outlined, size: 19),
                  onPressed: () => setState(() {
                    for (final p in widget.panes) {
                      _docks[p.id] =
                          p.id == 'inspector' && widget.initialPane == 'agent'
                          ? StudioDock.rightLower
                          : p.id == 'animation'
                          ? StudioDock.bottom
                          : p.id == 'scene' || p.id == 'assets'
                          ? StudioDock.left
                          : StudioDock.right;
                    }
                    _active[StudioDock.left] = 'scene';
                    _active[StudioDock.right] = widget.initialPane;
                    _active[StudioDock.rightLower] =
                        widget.initialPane == 'agent' &&
                            widget.panes.any((p) => p.id == 'inspector')
                        ? 'inspector'
                        : null;
                    _rightSplit = .5;
                    _active[StudioDock.bottom] = null;
                    _left = 260;
                    _right = 280;
                    _bottom = 200;
                  }),
                ),
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
      final left = !narrow && _active[StudioDock.left] != null
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
                  color: Colors.transparent,
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
                      : dock == StudioDock.left
                      ? rail
                      : c.maxWidth - rail - right,
                  top: isBottom
                      ? top + bodyHeight + gap
                      : splitRight && dock == StudioDock.rightLower
                      ? top + rightTopHeight + gap
                      : top,
                  width: isBottom
                      ? c.maxWidth - rail * 2
                      : dock == StudioDock.left
                      ? (left == 0 ? 260 : left)
                      : (right == 0 ? 280 : right),
                  height: isBottom
                      ? (bottom == 0 ? 200 : bottom) - gap
                      : splitRight && _isRight(dock)
                      ? (dock == StudioDock.right
                            ? rightTopHeight
                            : bodyHeight - rightTopHeight - gap)
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
                              child: Listener(
                                onPointerDown: (_) =>
                                    widget.onActivePanel?.call(pane.id),
                                child: pane.child,
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
              right: 0,
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
          if (!narrow)
            for (final dock in [
              StudioDock.left,
              StudioDock.right,
              StudioDock.bottom,
            ])
              Positioned(
                left: dock == StudioDock.right ? null : rail,
                right: dock == StudioDock.left ? null : rail,
                top: dock == StudioDock.bottom ? null : 0,
                bottom: dock == StudioDock.bottom ? 0 : null,
                width: dock == StudioDock.bottom ? null : 22,
                height: dock == StudioDock.bottom ? 22 : bodyHeight,
                child: DragTarget<String>(
                  onAcceptWithDetails: (d) => _move(d.data, dock),
                  builder: (_, candidates, _) => IgnorePointer(
                    child: ColoredBox(
                      color: candidates.isEmpty
                          ? Colors.transparent
                          : Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: .25),
                    ),
                  ),
                ),
              ),
        ],
      );
    },
  );
}
