import 'dart:async';
import 'package:zyren/zyren.dart';

/// Use the same name, version and value type to resolve an optional capability.
final class GeoServiceKey<T extends Object> {
  final String name;
  final int version;
  const GeoServiceKey(this.name, this.version);
  Type get valueType => T;
  @override
  String toString() => '$name@$version<$T>';
}

enum GeoExtensionState { attaching, attached, failed }

final class GeoExtensionRecord {
  final String id;
  final int contractVersion;
  final GeoExtensionState state;
  final Object? failure;
  const GeoExtensionRecord(
    this.id,
    this.contractVersion,
    this.state, [
    this.failure,
  ]);
}

final class GeoCapabilityChange {
  final String name;
  final int version;
  final Type valueType;
  final bool available;
  const GeoCapabilityChange(
    this.name,
    this.version,
    this.valueType,
    this.available,
  );
}

final class _Attachment {
  GeoExtensionRecord record;
  _Attachment(this.record);
}

final class _Provider {
  final Type type;
  final Object value;
  _Provider(this.type, this.value);
}

/// Active attachments and optional services for one geospatial host.
/// Keep each returned registration in the providing attachment's scope.
final class GeoExtensionRegistry {
  final _attachments = <String, _Attachment>{};
  final _providers = <(String, int), _Provider>{};
  final _changes = StreamController<List<GeoExtensionRecord>>.broadcast();
  final _capabilities = StreamController<GeoCapabilityChange>.broadcast();

  List<GeoExtensionRecord> get snapshot =>
      List.unmodifiable(_attachments.values.map((entry) => entry.record));
  Stream<List<GeoExtensionRecord>> get changes => _changes.stream;
  Stream<GeoCapabilityChange> get capabilityChanges => _capabilities.stream;

  Registration beginAttach(String id, int contractVersion) {
    if (id.trim().isEmpty || contractVersion < 1) {
      throw ArgumentError(
        'An attachment needs an ID and a positive contract version.',
      );
    }
    if (_attachments.containsKey(id)) {
      throw StateError('Extension $id is already attached.');
    }
    final entry = _Attachment(
      GeoExtensionRecord(id, contractVersion, GeoExtensionState.attaching),
    );
    _attachments[id] = entry;
    _changes.add(snapshot);
    return Registration(() {
      if (!identical(_attachments[id], entry)) return;
      _attachments.remove(id);
      _changes.add(snapshot);
    });
  }

  void markAttached(String id) => _mark(id, GeoExtensionState.attached);
  void markFailed(String id, Object failure) =>
      _mark(id, GeoExtensionState.failed, failure);

  void _mark(String id, GeoExtensionState state, [Object? failure]) {
    final entry = _attachments[id];
    if (entry == null) {
      throw StateError('Extension $id has no active attachment.');
    }
    entry.record = GeoExtensionRecord(
      id,
      entry.record.contractVersion,
      state,
      failure,
    );
    _changes.add(snapshot);
  }

  (String, int) _identity<T extends Object>(GeoServiceKey<T> key) {
    if (key.name.trim().isEmpty || key.version < 1) {
      throw ArgumentError(
        'A service needs a name and a positive contract version.',
      );
    }
    return (key.name, key.version);
  }

  Registration provide<T extends Object>(GeoServiceKey<T> key, T value) {
    final identity = _identity(key);
    if (_providers.containsKey(identity)) {
      throw StateError(
        'Service ${key.name}@${key.version} already has a provider.',
      );
    }
    final provider = _Provider(T, value);
    _providers[identity] = provider;
    _capabilities.add(GeoCapabilityChange(key.name, key.version, T, true));
    return Registration(() {
      if (!identical(_providers[identity], provider)) return;
      _providers.remove(identity);
      _capabilities.add(GeoCapabilityChange(key.name, key.version, T, false));
    });
  }

  T? find<T extends Object>(GeoServiceKey<T> key) {
    final provider = _providers[_identity(key)];
    if (provider == null) return null;
    if (provider.type != T) {
      throw StateError(
        'Service $key is registered with type ${provider.type}.',
      );
    }
    return provider.value as T;
  }
}
