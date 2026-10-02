import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'stats_overlay.dart';

/// Read-only scene inspection. Give it bounded width and height.
/// Selection is local unless supplied by the host; callbacks never mutate scenes.
class SceneInspector extends StatefulWidget {
  final SceneController controller;
  final Object3D? selectedObject;
  final ValueChanged<Object3D?>? onSelectionChanged;
  const SceneInspector({
    super.key,
    required this.controller,
    this.selectedObject,
    this.onSelectionChanged,
  });
  @override
  State<SceneInspector> createState() => _SceneInspectorState();
}

class _SceneInspectorState extends State<SceneInspector> {
  final _search = TextEditingController();
  final _collapsed = <Object3D>{};
  final _issues = <SceneIssue>[];
  StreamSubscription<int>? _sceneSubscription;
  StreamSubscription<SceneIssue>? _issueSubscription;
  Timer? _timer;
  Object3D? _selected;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    final controller = widget.controller;
    _selected = widget.selectedObject;
    controller.status.addListener(_statusChanged);
    _sceneSubscription = controller.scene.changes.listen((_) {
      if (!mounted || !identical(controller, widget.controller)) return;
      _timer ??= Timer(const Duration(milliseconds: 200), () {
        _timer = null;
        if (mounted) setState(() {});
      });
    });
    _issueSubscription = controller.issues.listen((issue) {
      if (!mounted || !identical(controller, widget.controller)) return;
      setState(() {
        _issues.add(issue);
        if (_issues.length > 8) _issues.removeAt(0);
      });
    });
  }

  void _statusChanged() {
    if (mounted) setState(() {});
  }

  void _unbind(SceneController controller) {
    controller.status.removeListener(_statusChanged);
    unawaited(_sceneSubscription?.cancel());
    unawaited(_issueSubscription?.cancel());
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didUpdateWidget(SceneInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _unbind(oldWidget.controller);
      _issues.clear();
      _collapsed.clear();
      _search.clear();
      _bind();
    } else if (!identical(oldWidget.selectedObject, widget.selectedObject)) {
      _selected = widget.selectedObject;
    }
  }

  @override
  void dispose() {
    _unbind(widget.controller);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final all = <(Object3D, int, bool)>[];
    final stack = [(controller.scene as Object3D, -1, true)];
    while (stack.isNotEmpty) {
      final (object, depth, parentVisible) = stack.removeLast();
      final visible = parentVisible && object.visible;
      if (depth >= 0) all.add((object, depth, visible));
      for (final child in object.children.reversed) {
        stack.add((child, depth + 1, visible));
      }
    }
    final members = all.map((entry) => entry.$1).toSet();
    _collapsed.removeWhere((node) => !members.contains(node));
    if (!members.contains(_selected)) _selected = null;
    final query = _search.text.trim().toLowerCase();
    final matches = <Object3D>{};
    if (query.isNotEmpty) {
      for (final (object, _, _) in all) {
        if (!_label(object).toLowerCase().contains(query)) continue;
        for (Object3D? node = object; node != null; node = node.parent) {
          matches.add(node);
        }
      }
    }
    final rows = <(Object3D, int, bool)>[];
    int? hiddenBelow;
    for (final row in all) {
      final (object, depth, _) = row;
      if (query.isNotEmpty) {
        if (matches.contains(object)) rows.add(row);
        continue;
      }
      if (hiddenBelow != null && depth > hiddenBelow) continue;
      hiddenBelow = _collapsed.contains(object) ? depth : null;
      rows.add(row);
    }
    final status = controller.status.value;
    final issue = status is SceneFailed ? status.issue : _issues.lastOrNull;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                Text(
                  'Scene inspector',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(_statusLabel(status)),
                Text(
                  '${all.length} objects · revision ${controller.scene.revision}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (status is SceneReady)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '${status.info.backend} · ${status.info.adapterName ?? 'Adapter unavailable'} · ${status.info.presentationPath.name}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          SceneStatsOverlay(controller: controller),
          if (issue != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '${issue.code}: ${issue.message}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                labelText: 'Find objects',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? SingleChildScrollView(
                    child: ZeroState(
                      title: query.isEmpty
                          ? 'No scene objects'
                          : 'No matching objects',
                      message: query.isEmpty
                          ? 'Add an object to your scene to inspect it here.'
                          : 'Try another object name.',
                      action: query.isEmpty
                          ? null
                          : TextButton(
                              onPressed: () => setState(_search.clear),
                              child: const Text('Clear search'),
                            ),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final (object, depth, visible) = rows[index];
                      return Padding(
                        padding: EdgeInsets.only(
                          left: math.min(depth, 4) * 12.0,
                        ),
                        child: Row(
                          children: [
                            if (object.children.isNotEmpty)
                              IconButton(
                                tooltip:
                                    '${_collapsed.contains(object) ? 'Expand' : 'Collapse'} ${_label(object)}',
                                icon: Icon(
                                  _collapsed.contains(object)
                                      ? Icons.chevron_right
                                      : Icons.expand_more,
                                ),
                                onPressed: () => setState(() {
                                  if (!_collapsed.add(object)) {
                                    _collapsed.remove(object);
                                  }
                                }),
                              )
                            else
                              const SizedBox(width: 40),
                            Expanded(
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                selected: identical(object, _selected),
                                title: Text(
                                  _label(object),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Icon(
                                  visible
                                      ? Icons.view_in_ar
                                      : Icons.visibility_off,
                                  size: 18,
                                ),
                                onTap: () {
                                  setState(() => _selected = object);
                                  widget.onSelectionChanged?.call(object);
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_selected case final object?)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.bodySmall!,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_label(object)} · ${object.runtimeType}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text('Position ${_vec(object.position)}'),
                        Text(
                          'Scale ${_vec(object.scale)} · layers 0x${object.layers.bits.toRadixString(16)}',
                        ),
                        Text(
                          'Local visibility ${object.visible ? 'on' : 'off'} · pixel visibility unverified',
                        ),
                        if (object is Mesh) ...[
                          Text(
                            '${object.geometry.vertexCount} vertices · ${object.geometry.topology.name} · ${object.material.runtimeType}',
                          ),
                          Text(
                            'Frustum culling ${object.frustumCulled ? 'on' : 'off'} · casts shadow ${object.castShadow}',
                          ),
                        ],
                        if (object is InstancedMesh)
                          Text('${object.count} instances'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _label(Object3D object) => object.name?.isNotEmpty == true
    ? object.name!
    : object.runtimeType.toString();
String _vec(Vec3 value) => [value.x, value.y, value.z]
    .map(
      (v) => v == v.roundToDouble()
          ? v.toStringAsFixed(0)
          : v.toStringAsPrecision(4),
    )
    .join(', ');
String _statusLabel(SceneStatus status) => switch (status) {
  SceneDetached() => 'Detached',
  SceneInitializing() => 'Initializing',
  SceneReady() => 'Ready',
  SceneSuspended() => 'Suspended',
  SceneRecovering() => 'Recovering',
  SceneFailed() => 'Failed',
  SceneDisposed() => 'Disposed',
};
