/// Teardown continues after one owner fails. The caller retains failed handles
/// for retry, and can discard its presenter when the owning session retires.
Future<
  ({
    bool serverClosed,
    bool presenterClosed,
    bool sessionClosed,
    List<Object> errors,
  })
>
releaseProbeResources({
  Future<void> Function()? closeServer,
  Future<void> Function()? closePresenter,
  required List<void Function()> releaseLocal,
  Future<void> Function()? disposeSession,
}) async {
  final errors = <Object>[];
  Future<bool> attempt(Future<void> Function()? close) async {
    try {
      await close?.call();
      return true;
    } catch (error) {
      errors.add(error);
      return false;
    }
  }

  final serverClosed = await attempt(closeServer);
  final presenterClosed = await attempt(closePresenter);
  for (final close in releaseLocal) {
    try {
      close();
    } catch (error) {
      errors.add(error);
    }
  }
  final sessionClosed = await attempt(disposeSession);
  return (
    serverClosed: serverClosed,
    presenterClosed: presenterClosed,
    sessionClosed: sessionClosed,
    errors: List<Object>.unmodifiable(errors),
  );
}
