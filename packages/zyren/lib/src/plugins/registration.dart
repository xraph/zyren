/// A removable registration. Disposal runs at most once, even if it throws.
class Registration {
  void Function()? _release;
  Registration(void Function() release) : _release = release;
  bool get isDisposed => _release == null;
  void dispose() {
    final release = _release;
    _release = null;
    release?.call();
  }
}
