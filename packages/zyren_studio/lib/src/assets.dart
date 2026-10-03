part of '../zyren_studio.dart';

/// The adapter loads the saved pin. It must never substitute a newer asset.
abstract interface class StudioAssetResolver {
  Future<StudioAssetTemplate> load(
    StudioAsset asset,
    LoadCancellation cancellation,
  );
}

abstract interface class StudioAssetTemplate {
  StudioAssetInstance instantiate();
  Future<void> close();
}

final class StudioAssetInstance {
  final Object3D root;
  final Map<String, Object3D> sources;
  StudioAssetInstance(this.root, {Map<String, Object3D> sources = const {}})
    : sources = Map.unmodifiable(sources);
}

/// One document or preview owns one scope. Close it after retiring its renderer.
final class StudioAssetScope {
  final _templates = <String, (String, StudioAssetTemplate)>{};
  bool _closed = false;
  StudioAssetScope._();
  int get templateCount => _templates.length;
  bool get isClosed => _closed;

  static Future<StudioAssetScope> load(
    StudioDocument document,
    StudioAssetResolver resolver, {
    LoadCancellation? cancellation,
  }) async {
    final token = cancellation ?? StudioCancellation();
    final scope = StudioAssetScope._();
    try {
      final used = document.expandedNodes.values.map((n) => n.assetId).toSet();
      for (final asset in document.assets.where((a) => used.contains(a.id))) {
        token.throwIfCancelled();
        final template = await resolver.load(asset, token);
        scope._templates[asset.id] = (jsonEncode(asset.toJson()), template);
        token.throwIfCancelled();
      }
      return scope;
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  StudioAssetInstance instantiate(StudioAsset asset) {
    final entry = _templates[asset.id];
    if (_closed || entry == null || entry.$1 != jsonEncode(asset.toJson())) {
      throw StateError(
        'Load the exact asset descriptor before reconstruction.',
      );
    }
    final instance = entry.$2.instantiate();
    final members = <Object3D>{};
    void visit(Object3D object) {
      if (!members.add(object)) throw StateError('Invalid imported hierarchy.');
      for (final child in object.children) {
        visit(child);
      }
    }

    if (instance.root.parent != null) {
      throw StateError('Asset factories must return independent instances.');
    }
    visit(instance.root);
    if (instance.sources.keys
            .toSet()
            .difference(asset.sourceNodes.keys.toSet())
            .isNotEmpty ||
        asset.sourceNodes.keys
            .toSet()
            .difference(instance.sources.keys.toSet())
            .isNotEmpty ||
        instance.sources.values.toSet().length != instance.sources.length ||
        !members.containsAll(instance.sources.values)) {
      throw StateError(
        'Asset source bindings differ from the saved descriptor.',
      );
    }
    return instance;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final templates = _templates.values.map((v) => v.$2).toList();
    _templates.clear();
    Object? firstError;
    StackTrace? firstStack;
    for (final template in templates.reversed) {
      try {
        await template.close();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

/// Host-owned cancellation, shared by the pipeline and the editor load.
final class StudioCancellation implements LoadCancellation {
  final _callbacks = <Object, void Function()>{};
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return Registration(() {});
    }
    final key = Object();
    _callbacks[key] = callback;
    return Registration(() => _callbacks.remove(key));
  }

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    final callbacks = _callbacks.values.toList();
    _callbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }
}
