import 'package:flutter/services.dart';

import 'models.dart';
import 'session.dart';

final class MethodChannelXrTransport implements XrTransport {
  final MethodChannel channel;
  const MethodChannelXrTransport({
    this.channel = const MethodChannel('dev.zyren.xr/session.v1'),
  });

  @override
  Future<Object?> invoke(String method, Map<String, Object?> arguments) async {
    try {
      return await channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const XrException(
        'adapterUnavailable',
        'The XR native adapter is not registered on this platform.',
      );
    } on PlatformException catch (error) {
      throw XrException(
        error.code,
        error.message ?? 'Native XR call failed.',
        error.details,
      );
    }
  }
}
