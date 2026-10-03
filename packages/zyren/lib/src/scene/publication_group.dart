part of 'scene.dart';

/// Owns candidate and displayed children until a renderer confirms publication.
/// [children] includes both sets; rendering uses [renderChildren] and CPU picking
/// uses [pickChildren]. Ordinary groups use the same children for both.
///
/// You must keep displayed child state immutable while staging replacements.
/// This boundary retains membership and parent ownership, not a snapshot of
/// arbitrary edits. Publish the exact submitted set after a successful receipt.
class PublicationGroup extends Group {
  List<Object3D> _candidate = const [], _displayed = const [];
  PublicationGroup({super.name});
  @override
  List<Object3D> get renderChildren => _candidate;
  @override
  List<Object3D> get pickChildren => _displayed;

  /// Direct additions join the candidate set. Call [publish] after rendering.
  @override
  T add<T extends Object3D>(T child) {
    stage([..._candidate, child]);
    return child;
  }

  /// Removal and reparenting retire membership in both traversals.
  @override
  void remove(Object3D child) {
    _candidate = List.unmodifiable(
      _candidate.where((n) => !identical(n, child)),
    );
    _displayed = List.unmodifiable(
      _displayed.where((n) => !identical(n, child)),
    );
    super.remove(child);
  }

  void stage(Iterable<Object3D> children) => _set(children, false);
  void publish(Iterable<Object3D> children) => _set(children, true);

  void _set(Iterable<Object3D> values, bool publication) {
    final next = List<Object3D>.unmodifiable(values.toSet());
    final old = publication ? _displayed : _candidate;
    if (next.length == old.length &&
        Iterable<int>.generate(
          next.length,
        ).every((i) => identical(next[i], old[i]))) {
      return;
    }
    batch(() {
      for (final child in next) {
        super.add(child);
      }
      if (publication) {
        _displayed = next;
      } else {
        _candidate = next;
      }
      final retained = {..._candidate, ..._displayed};
      for (final child in children) {
        if (!retained.contains(child)) remove(child);
      }
      _changed();
    });
  }
}
