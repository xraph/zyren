import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/network.dart';
import 'studio_collaboration.dart';

class StudioCollaborationDialog extends StatefulWidget {
  final StudioScene scene;
  final Directory? directory;
  final void Function(StudioCollaborationSession?) onSession;
  const StudioCollaborationDialog({
    super.key,
    required this.scene,
    this.directory,
    required this.onSession,
  });
  @override
  State<StudioCollaborationDialog> createState() =>
      _StudioCollaborationDialogState();
}

class _StudioCollaborationDialogState extends State<StudioCollaborationDialog> {
  final _endpoint = TextEditingController();
  final _token = TextEditingController();
  final _label = TextEditingController(text: 'Studio editor');
  StudioCollaborationSession? _session;
  StudioRoom? _room;
  Timer? _poll;
  String? _error, _selected;
  bool _busy = false, _shareCamera = false;
  int _presenceSequence = 0, _ticks = 0;
  List<ScenePresence> _people = [];
  SceneHistoryPage? _history;
  OfflineSceneState? _offline;
  StreamSubscription<SceneSnapshot>? _changes;
  @override
  void initState() {
    super.initState();
    _selected =
        widget.scene.idFor(widget.scene.tools.selected) ??
        widget.scene.objects.keys.firstOrNull;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
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

  Future<void> _connect(bool host) => _run(() async {
    final directory =
        widget.directory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/studio-collaboration',
        );
    final scene = widget.scene;
    final epoch = studioEpoch(scene.capture());
    final StudioCollaborationSession session;
    if (host) {
      final room = await StudioRoom.host(scene, directory);
      _room = room;
      session = await StudioCollaborationSession.connect(
        scene: scene,
        transport: room.authority.connect('owner'),
        presence: room.presence.connect('owner'),
        directory: directory,
        ownerId: 'local-owner',
        label: _label.text,
      );
    } else {
      final uri = Uri.parse(_endpoint.text.trim());
      final token = _token.text;
      final transport = HttpSceneTransport(
        endpoint: uri,
        sceneId: scene.document.id,
        epoch: epoch,
        headers: () => {'Authorization': 'Bearer $token'},
      );
      final identity = sha256.convert(utf8.encode('$uri:$token')).toString();
      session = await StudioCollaborationSession.connect(
        scene: scene,
        transport: transport,
        presence: transport,
        directory: directory,
        ownerId: identity,
        label: _label.text,
        closeTransport: transport.close,
      );
    }
    if (!mounted) {
      await session.close();
      await _room?.close();
      return;
    }
    _session = session;
    widget.onSession(session);
    _changes = session.client.changes.listen((_) {
      if (mounted) setState(() {});
    });
    await _refresh();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_busy && !session.client.isBusy && !session.client.isClosed) {
        unawaited(_run(_refresh));
      }
    });
  });
  Future<void> _refresh() async {
    final session = _session!;
    await session.refresh();
    _people = await session.presence.participants();
    _offline = await session.offline.read();
    _history = await (session.client.transport as SceneCollaborationQueries)
        .history(
          expectedRevision: session.client.snapshot!.revision,
          afterRevision: (session.client.snapshot!.revision - 50).clamp(
            0,
            session.client.snapshot!.revision,
          ),
          limit: 50,
        );
    if (_ticks++ % 5 == 0) {
      await session.publish(
        ++_presenceSequence,
        selectedId: _selected,
        shareCamera: _shareCamera,
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _pose({bool queue = false}) async {
    final session = _session!;
    final object = widget.scene.objects[_selected]!;
    final values = [
      object.position.x,
      object.position.y,
      object.position.z,
      object.quaternion.x,
      object.quaternion.y,
      object.quaternion.z,
      object.quaternion.w,
      object.scale.x,
      object.scale.y,
      object.scale.z,
    ];
    final fields = values
        .map((v) => TextEditingController(text: '$v'))
        .toList();
    String? error;
    SceneTransform? pose;
    try {
      pose = await showDialog<SceneTransform>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Shared local transform'),
            content: SizedBox(
              width: 320,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < fields.length; i++)
                      TextField(
                        controller: fields[i],
                        decoration: InputDecoration(
                          labelText: [
                            'Position X',
                            'Position Y',
                            'Position Z',
                            'Quaternion X',
                            'Quaternion Y',
                            'Quaternion Z',
                            'Quaternion W',
                            'Scale X',
                            'Scale Y',
                            'Scale Z',
                          ][i],
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                      ),
                    if (error != null) Text(error!),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  try {
                    final v = fields.map((f) => double.parse(f.text)).toList();
                    Navigator.pop(
                      context,
                      SceneTransform(
                        position: Vec3(v[0], v[1], v[2]),
                        rotation: Quat(v[3], v[4], v[5], v[6]),
                        scale: Vec3(v[7], v[8], v[9]),
                      ),
                    );
                  } catch (_) {
                    update(
                      () => error =
                          'Use finite values, a nonzero quaternion and nonzero scales.',
                    );
                  }
                },
                child: Text(queue ? 'Queue pose' : 'Apply shared pose'),
              ),
            ],
          ),
        ),
      );
    } finally {
      for (final field in fields) {
        field.dispose();
      }
    }
    if (pose != null) {
      await _run(() async {
        if (queue) {
          await session.queueTransform(_selected!, pose!);
        } else {
          await session.transform(_selected!, pose!);
        }
        await _refresh();
      });
    }
  }

  Future<void> _close() async {
    _poll?.cancel();
    _poll = null;
    widget.onSession(null);
    await _changes?.cancel();
    _changes = null;
    await _session?.close();
    _session = null;
    await _room?.close();
    _room = null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_changes?.cancel());
    unawaited(
      _session != null
          ? _session!.close().whenComplete(() => _room?.close())
          : _room?.close(),
    );
    _endpoint.dispose();
    _token.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final pending = session?.client.pending;
    final conflict = session?.client.conflict;
    final offlineConflict = _offline?.conflict;
    return PopScope(
      canPop: session == null,
      child: Dialog(
        alignment: Alignment.bottomRight,
        insetPadding: const EdgeInsets.all(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Shared session',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close shared session',
                      onPressed: _busy
                          ? null
                          : () async {
                              await _close();
                              if (context.mounted) Navigator.pop(context);
                            },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const Text(
                  'Shared transforms and visibility. Joining adopts the session state and clears local undo history. Close the session to author structure or materials.',
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
                Flexible(
                  child: SingleChildScrollView(
                    child: session == null
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(
                                controller: _label,
                                decoration: const InputDecoration(
                                  labelText: 'Presence label',
                                ),
                              ),
                              TextField(
                                controller: _endpoint,
                                decoration: const InputDecoration(
                                  labelText:
                                      'Service endpoint (HTTPS, or loopback HTTP)',
                                ),
                              ),
                              TextField(
                                controller: _token,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Access token',
                                ),
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _connect(false),
                                    child: const Text('Join session'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _connect(true),
                                    child: const Text('Host local session'),
                                  ),
                                ],
                              ),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Revision ${session.client.snapshot!.revision} · ${_people.length} present',
                              ),
                              if (_room case final room?)
                                ExpansionTile(
                                  tilePadding: EdgeInsets.zero,
                                  title: const Text('Local connection details'),
                                  children: [
                                    SelectableText(
                                      room.server.endpoint.toString(),
                                    ),
                                    const Text('Editor token'),
                                    SelectableText(room.editorToken),
                                    const Text('Viewer token'),
                                    SelectableText(room.viewerToken),
                                    const Text(
                                      'Loopback only. Remote hosts need their own authenticated service.',
                                    ),
                                  ],
                                ),
                              DropdownButtonFormField<String>(
                                initialValue: _selected,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Object',
                                ),
                                items: [
                                  for (final entry
                                      in widget
                                          .scene
                                          .document
                                          .expandedNodes
                                          .entries)
                                    DropdownMenuItem(
                                      value: entry.key,
                                      child: Text(
                                        entry.value.label,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (value) =>
                                          setState(() => _selected = value),
                              ),
                              Wrap(
                                spacing: 4,
                                children: [
                                  TextButton(
                                    onPressed:
                                        _busy ||
                                            pending != null ||
                                            _selected == null
                                        ? null
                                        : () => _pose(),
                                    child: const Text('Transform'),
                                  ),
                                  TextButton(
                                    onPressed:
                                        _busy ||
                                            pending != null ||
                                            _selected == null
                                        ? null
                                        : () => _run(() async {
                                            await session.visible(
                                              _selected!,
                                              !widget
                                                  .scene
                                                  .objects[_selected]!
                                                  .visible,
                                            );
                                            await _refresh();
                                          }),
                                    child: const Text('Toggle visibility'),
                                  ),
                                  TextButton(
                                    onPressed: _busy || _selected == null
                                        ? null
                                        : () => _pose(queue: true),
                                    child: const Text('Queue offline pose'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _run(() async {
                                            await session.reconcile();
                                            await _refresh();
                                          }),
                                    child: const Text('Reconcile outbox'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _run(_refresh),
                                    child: const Text('Refresh'),
                                  ),
                                ],
                              ),
                              Text(
                                'Outbox: ${_offline?.pending.length ?? 0} pending${_offline?.lastError == null ? '' : ' (${_offline!.lastError})'}',
                              ),
                              if (pending != null)
                                Text(
                                  'Pending ${pending.field.name} for ${pending.objectId.key}. Retry retains the exact operation ID.',
                                ),
                              if (pending != null && conflict == null)
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(() async {
                                          await session.retryPending();
                                          await _refresh();
                                        }),
                                  child: const Text('Retry pending write'),
                                ),
                              if (conflict != null) ...[
                                Text(
                                  'Conflict: proposed ${conflict.operation.transform?.toJson() ?? conflict.operation.visible}; current ${conflict.current.transform.toJson()} / visible ${conflict.current.visible}',
                                ),
                                Wrap(
                                  children: [
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(() async {
                                              await session.keepLocal();
                                              await _refresh();
                                            }),
                                      child: const Text('Keep proposed value'),
                                    ),
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(() async {
                                              await session.acceptRemote();
                                              await _refresh();
                                            }),
                                      child: const Text('Accept current value'),
                                    ),
                                  ],
                                ),
                              ],
                              if (offlineConflict != null) ...[
                                Text(
                                  'Outbox conflict on ${offlineConflict.operation.objectId.key}: field revision ${offlineConflict.actualRevision}',
                                ),
                                Wrap(
                                  children: [
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(() async {
                                              await session.offline.keepLocal(
                                                session.client
                                                    .nextOperationId(),
                                                reviewed: offlineConflict,
                                              );
                                              await session.reconcile();
                                              await _refresh();
                                            }),
                                      child: const Text('Keep queued value'),
                                    ),
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(() async {
                                              await session.offline
                                                  .acceptRemote(
                                                    reviewed: offlineConflict,
                                                  );
                                              await _refresh();
                                            }),
                                      child: const Text(
                                        'Accept remote for outbox',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Share camera'),
                                value: _shareCamera,
                                onChanged: _busy
                                    ? null
                                    : (value) => _run(() async {
                                        _shareCamera = value!;
                                        await session.publish(
                                          ++_presenceSequence,
                                          selectedId: _selected,
                                          shareCamera: _shareCamera,
                                        );
                                      }),
                              ),
                              for (final person in _people.where(
                                (p) => p.sessionId != session.sessionId,
                              ))
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(person.label),
                                  trailing: TextButton(
                                    onPressed: person.camera == null
                                        ? null
                                        : () => setState(() {
                                            session.follower.follow(
                                              person.sessionId,
                                            );
                                            session.follower.update(_people);
                                          }),
                                    child: const Text('Follow camera'),
                                  ),
                                ),
                              if (session.follower.sessionId != null)
                                TextButton(
                                  onPressed: () =>
                                      setState(session.follower.stop),
                                  child: const Text('Stop following'),
                                ),
                              const Text('Recent operations'),
                              for (final record
                                  in _history?.records.reversed ??
                                      const <SceneOperationRecord>[])
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    '#${record.revision} ${record.operation.objectId.key}: ${record.operation.field.name}',
                                  ),
                                  trailing: TextButton(
                                    onPressed: _busy || pending != null
                                        ? null
                                        : () => _run(() async {
                                            await session.undo(record.revision);
                                            await _refresh();
                                          }),
                                    child: const Text('Invert'),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
