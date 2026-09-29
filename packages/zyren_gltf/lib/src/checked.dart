import 'package:zyren/zyren.dart';

Object? field(Map<String, Object?> value, String key, Object? fallback) =>
    value.containsKey(key) ? value[key] : fallback;

Never fail(
  String path,
  String message, [
  AssetLoadError code = AssetLoadError.invalidData,
]) => throw AssetLoadException(code, message, fieldPath: path);

Map<String, Object?> object(Object? value, String path) {
  if (value is! Map<String, Object?>) fail(path, 'Expected an object.');
  return value;
}

List<Object?> array(Object? value, String path) {
  if (value is! List<Object?>) fail(path, 'Expected an array.');
  return value;
}

int integer(Object? value, String path, {int min = 0, int max = 0x7fffffff}) {
  if (value is! num ||
      !value.isFinite ||
      value < min ||
      value > max ||
      value != value.truncateToDouble()) {
    fail(path, 'Expected an integer between $min and $max.');
  }
  return value.toInt();
}

double number(Object? value, String path) {
  if (value is! num || !value.isFinite) fail(path, 'Expected a finite number.');
  return value.toDouble();
}

String string(Object? value, String path) {
  if (value is! String) fail(path, 'Expected a string.');
  return value;
}

bool boolean(Object? value, String path) {
  if (value is! bool) fail(path, 'Expected a boolean.');
  return value;
}

int index(Object? value, int length, String path) {
  final result = integer(value, path);
  if (result >= length) fail(path, 'Index is outside the referenced array.');
  return result;
}

class DecodeBudget {
  final int maxBytes;
  int usedBytes = 0;
  DecodeBudget(this.maxBytes) {
    RangeError.checkNotNegative(maxBytes, 'maxBytes');
  }
  void reserve(int bytes, String path) {
    if (bytes < 0 || bytes > maxBytes - usedBytes) {
      fail(
        path,
        'Decoded payload exceeds its byte budget.',
        AssetLoadError.limitExceeded,
      );
    }
    usedBytes += bytes;
  }
}

List<double> numbers(Object? value, int count, String path) {
  final values = array(value, path);
  if (values.length != count) fail(path, 'Expected $count components.');
  return [for (var i = 0; i < count; i++) number(values[i], '$path[$i]')];
}
