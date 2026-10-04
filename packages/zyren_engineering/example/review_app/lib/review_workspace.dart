import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_engineering/cad_bundle.dart';
import 'package:zyren_engineering/file_store.dart';
import 'package:zyren_engineering/http_session_store.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'model_bounds.dart';

class _BundleSource implements ByteSourceResolver {
  final Uint8List bytes;
  _BundleSource(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    if (uri.toString() != 'memory:model.glb') {
      throw const FormatException(
        'CAD bundles must contain embedded resources.',
      );
    }
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}

/// Host state stays outside the pure Dart engineering plugin.
class ReviewWorkspace extends ChangeNotifier {
  final SceneController controller;
  final SceneEngineeringPlugin review;
  late final StreamSubscription<void> _changes;
  late final List<Registration> _gestures;
  AssetScope? _assets;
  Group? root;
  Directory? directory;
  String? selectedId;
  Vec3 anchor = Vec3.zero;
  String label = 'No model',
      version = '',
      message = 'Open a CAD bundle to begin.';
  String? error;
  bool busy = false, _closed = false;
  Future<void> Function()? retry;
  HttpClient? _client;
  EngineeringSessionStore? session;
  String? endpoint;
  EngineeringRevision? base;
  final _bases = <String, EngineeringRevision>{};
  List<EngineeringConflict> conflicts = [];
  final choices = <EngineeringConflict, EngineeringConflictChoice>{};
  final _pins = <Mesh>[];
  double radius = 1, distance = 5, yaw = .65, pitch = .35, _gestureDistance = 5;
  Vec3 target = Vec3.zero;
  Process? _converter;

  ReviewWorkspace({
    required SceneRuntime runtime,
    PresentationPolicy presentation = PresentationPolicy.requireNative,
    String documentId = 'review',
  }) : controller = SceneController(
         runtime: runtime,
         options: EngineOptions(presentation: presentation),
       ),
       review = SceneEngineeringPlugin(
         document: EngineeringDocument(id: documentId),
       ) {
    controller.use(review);
    controller.scene.background = const Color3(.035, .05, .075);
    controller.scene.add(
      DirectionalLight(direction: const Vec3(-1, -2, -1), intensity: 3),
    );
    controller.scene.add(HemisphereLight(intensity: .7));
    _gestures = [
      for (final gesture in [
        SceneGesture.tap,
        SceneGesture.scale,
        SceneGesture.scroll,
      ])
        controller.input.registerGesture(gesture),
    ];
    _changes = review.changes.listen((_) {
      if (!_closed) {
        _updatePins();
        notifyListeners();
      }
    });
    _camera();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> perform(Future<void> Function() operation) async {
    if (busy || _closed) return;
    busy = true;
    error = null;
    retry = () => perform(operation);
    _notify();
    try {
      await operation();
    } catch (e) {
      if (!_closed) error = e.toString();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> demo() => perform(() async {
    final data = await rootBundle.load('assets/demo/model.glb');
    final bundle = EngineeringCadBundle.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      await rootBundle.loadString('assets/demo/review.json'),
    );
    await _install(bundle, null, 'IFC housing');
  });
  Future<void> open(Directory folder) => perform(() async {
    await _install(
      await EngineeringCadBundle.read(folder),
      folder,
      folder.uri.pathSegments.where((s) => s.isNotEmpty).last,
    );
  });
  Future<void> reload() => directory == null ? demo() : open(directory!);

  Future<void> _install(
    EngineeringCadBundle bundle,
    Directory? folder,
    String name,
  ) async {
    await controller.ready;
    if (_closed) return;
    final assets = AssetScope(
      services: AssetServices(resolver: _BundleSource(bundle.bytes)),
    );
    Group? next;
    try {
      final model = await assets
          .load(
            Gltf.uri(Uri.parse('memory:model.glb'), version: bundle.version),
          )
          .result;
      if (_closed) {
        await assets.close();
        return;
      }
      next = model.instantiate();
      final imported = EngineeringImport.fromSidecar(
        root: next,
        modelVersion: bundle.version,
        source: bundle.sidecar,
      );
      final bounds = await modelBounds(next, () => _closed);
      controller.scene.add(next);
      review.rebindImport(imported);
      final old = root, oldAssets = _assets;
      root = next;
      _assets = assets;
      directory = folder;
      label = name;
      version = bundle.version;
      if (old != null) controller.scene.remove(old);
      await oldAssets?.close();
      selectedId = review.document.objects.containsKey(selectedId)
          ? selectedId
          : imported.entries.first.record.id;
      anchor = Vec3.zero;
      target = bounds.center;
      radius = bounds.radius;
      fit();
      _updatePins();
      message = '${imported.entries.length} source objects loaded';
    } catch (_) {
      if (next?.parent != null) controller.scene.remove(next!);
      await assets.close();
      rethrow;
    }
  }

  Future<void> convert({
    required String python,
    required String script,
    required String source,
    required String destination,
    String? identityMap,
    double? metersPerUnit,
  }) => perform(() async {
    if (python.trim().isEmpty || script.trim().isEmpty)
      throw ArgumentError('Choose a Python environment and converter script.');
    message = 'Converting CAD';
    _notify();
    final process = await Process.start(python, [
      script,
      source,
      destination,
      if (identityMap != null) ...['--identity-map', identityMap],
      if (metersPerUnit != null) ...['--meters-per-unit', '$metersPerUnit'],
    ]);
    _converter = process;
    if (_closed) process.kill();
    var stderr = '';
    final errorDone = Completer<void>(), outputDone = Completer<void>();
    final errors = process.stderr.listen(
      (bytes) {
        if (stderr.length < 8192)
          stderr += String.fromCharCodes(bytes.take(8192 - stderr.length));
      },
      onDone: errorDone.complete,
      onError: errorDone.completeError,
    );
    final output = process.stdout.listen(
      (_) {},
      onDone: outputDone.complete,
      onError: outputDone.completeError,
    );
    int exit;
    try {
      exit =
          await (() async {
            final code = await process.exitCode;
            await Future.wait([errorDone.future, outputDone.future]);
            return code;
          })().timeout(
            const Duration(minutes: 5),
            onTimeout: () {
              process.kill();
              throw TimeoutException('CAD conversion exceeded five minutes.');
            },
          );
    } finally {
      await errors.cancel();
      await output.cancel();
      _converter = null;
    }
    if (_closed) return;
    if (exit != 0)
      throw StateError(
        stderr.isEmpty ? 'CAD conversion failed ($exit).' : stderr.trim(),
      );
    final folder = Directory(destination);
    await _install(
      await EngineeringCadBundle.read(folder),
      folder,
      File(source).uri.pathSegments.last,
    );
  });

  void select(String id, [Vec3 local = Vec3.zero]) {
    selectedId = id;
    anchor = local;
    _notify();
  }

  void putNote(String text, {EngineeringAnnotation? existing}) {
    final id = existing?.objectId ?? selectedId;
    if (id == null || text.trim().isEmpty || busy) return;
    review.putAnnotation(
      EngineeringAnnotation(
        id: existing?.id ?? 'note-${DateTime.now().microsecondsSinceEpoch}',
        objectId: id,
        text: text.trim(),
        anchor: existing?.anchor ?? anchor,
      ),
    );
    message = 'Local edit saved in memory';
    _notify();
  }

  void removeNote(String id) {
    if (!busy) review.removeAnnotation(id);
  }

  void isolate() {
    if (selectedId != null && review.objectFor(selectedId!) != null)
      review.isolate({selectedId!});
  }

  void showAll() => review.restoreVisibility();
  Future<void> save(File file) => perform(() async {
    await review.save(FileEngineeringStore(file));
    message = 'Saved ${file.uri.pathSegments.last}';
  });
  Future<void> loadNotes(File file) => perform(() async {
    if (!await review.load(FileEngineeringStore(file)))
      throw const FileSystemException('Review file was not found.');
    // Imported geometry is already bound; records missing from the saved review stay unbound.
    message = 'Local review loaded';
  });

  Future<void> connect(String url, String token) => perform(() async {
    final uri = Uri.parse(url.trim());
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final store = HttpEngineeringSessionStore(
        client: client,
        endpoint: uri,
        headers: () async => {'Authorization': 'Bearer ${token.trim()}'},
      );
      await attachSession(store, uri.toString());
      if (_closed) {
        client.close(force: true);
        return;
      }
      _client?.close(force: true);
      _client = client;
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  });

  /// Reading a first session never acknowledges unreviewed remote edits.
  Future<void> attachSession(
    EngineeringSessionStore store,
    String identity,
  ) async {
    final remote = await store.read().timeout(const Duration(seconds: 20));
    if (remote.document.id != review.document.id)
      throw const FormatException(
        'Session belongs to another review document.',
      );
    if (_closed) return;
    session = store;
    endpoint = identity;
    base =
        _bases[identity] ??
        EngineeringRevision(
          version: remote.version,
          document: EngineeringDocument(id: review.document.id),
        );
    conflicts = [];
    choices.clear();
    message = 'Connected. Sync to review shared changes.';
    _notify();
  }

  void disconnect() {
    _client?.close(force: true);
    _client = null;
    session = null;
    endpoint = null;
    base = null;
    conflicts = [];
    choices.clear();
    message = 'Disconnected; local edits kept';
    _notify();
  }

  Future<void> sync() => perform(() async {
    if (session == null || base == null) return;
    final result = await review.synchronize(
      session!,
      base: base!,
      resolutions: [
        for (final entry in choices.entries)
          EngineeringConflictResolution(entry.key, entry.value),
      ],
    );
    conflicts = result.conflicts;
    choices.clear();
    if (result.written) {
      base = result.revision;
      _bases[endpoint!] = result.revision;
      message = 'Shared revision ${result.revision.version} saved';
    } else {
      message = '${conflicts.length} conflicts need your choice';
    }
  });
  void choose(EngineeringConflict conflict, EngineeringConflictChoice choice) {
    choices[conflict] = choice;
    _notify();
  }

  void _updatePins() {
    for (final pin in _pins) {
      pin.parent?.remove(pin);
    }
    _pins.clear();
    for (final note in review.document.annotations.values) {
      final object = review.objectFor(note.objectId);
      if (object == null) continue;
      final pin = Mesh(
        SphereGeometry(
          radius: math.max(radius * .018, .005),
          widthSegments: 12,
          heightSegments: 8,
        ),
        UnlitMaterial(color: const Color3(1, .5, .1)),
        name: 'Review note',
      )..position = note.anchor;
      _pins.add(pin);
      object.add(pin);
    }
  }

  void fit() {
    yaw = .65;
    pitch = .35;
    distance = radius * 3.8;
    _camera();
  }

  void _camera() {
    controller.camera.target = target;
    controller.camera.position =
        target +
        Vec3(
              math.sin(yaw) * math.cos(pitch),
              math.sin(pitch),
              math.cos(yaw) * math.cos(pitch),
            ) *
            distance;
    final camera = controller.camera as PerspectiveCamera;
    camera.near = math.max(radius / 1000, .000001);
    camera.far = math.max(distance + radius * 10, 10);
  }

  void pointer(ScenePointerEvent event) {
    if (event.phase == ScenePointerPhase.tap) {
      unawaited(_pick(event.point));
    }
    if (event.phase == ScenePointerPhase.scaleStart)
      _gestureDistance = distance;
    if (event.phase == ScenePointerPhase.scaleUpdate) {
      yaw -= event.delta.x * .008;
      pitch = (pitch + event.delta.y * .008).clamp(-1.45, 1.45);
      distance = (_gestureDistance / event.scale).clamp(
        radius * 1.1,
        radius * 100,
      );
      _camera();
    } else if (event.phase == ScenePointerPhase.scroll) {
      distance = (distance * math.exp((event.delta.y * .001).clamp(-2, 2)))
          .clamp(radius * 1.1, radius * 100);
      _camera();
    }
  }

  Future<void> _pick(ViewportPoint point) async {
    if (busy || _closed) return;
    final hit = await controller.pick(point);
    if (hit == null || _closed) return;
    for (
      Object3D? object = hit.object;
      object != null;
      object = object.parent
    ) {
      final id = review.idFor(object);
      if (id != null) {
        select(id, review.localAnchor(id, hit.point));
        return;
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _converter?.kill();
    _client?.close(force: true);
    unawaited(_changes.cancel());
    for (final gesture in _gestures) {
      gesture.dispose();
    }
    controller.dispose();
    final assets = _assets;
    unawaited(controller.whenDisposed.whenComplete(() => assets?.close()));
    super.dispose();
  }
}
