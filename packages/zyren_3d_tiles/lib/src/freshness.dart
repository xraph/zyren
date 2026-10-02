part of '../zyren_3d_tiles.dart';

/// HTTP freshness governs reuse after a tile leaves the active selection.
/// Active geometry remains owned by the current visualization between frames.
final class _TileFreshness {
  bool retain = true;
  DateTime? expires;
  bool reusable(DateTime now) =>
      retain && (expires == null || now.isBefore(expires!));
  void include(Map<String, String> headers, DateTime received) {
    final controls = (headers['cache-control'] ?? '')
        .toLowerCase()
        .split(',')
        .map((value) => value.trim())
        .toList();
    if (controls.any(
      (s) => ['no-cache', 'no-store'].contains(s.split('=').first),
    )) {
      retain = false;
    }
    final ages = controls.where((s) => s.startsWith('max-age=')).toList();
    DateTime? deadline;
    if (ages.isNotEmpty) {
      final seconds = ages.length == 1
          ? int.tryParse(ages.single.substring(8).replaceAll('"', ''))
          : null;
      if (seconds == null || seconds < 0 || seconds > 315360000) {
        retain = false;
      } else {
        final age = int.tryParse(headers['age'] ?? '0');
        if (age == null || age < 0) retain = false;
        final date = _httpDate(headers['date']);
        final elapsed = date == null
            ? 0
            : math.max(0, received.difference(date).inSeconds);
        final spent = math.max(age ?? 0, elapsed);
        deadline = received.add(
          Duration(seconds: math.max(0, seconds - spent)),
        );
      }
    } else if (headers.containsKey('expires')) {
      final expiration = _httpDate(headers['expires']);
      if (expiration == null) retain = false;
      deadline = expiration;
    }
    if (deadline != null && (expires == null || deadline.isBefore(expires!))) {
      expires = deadline;
    }
  }
}

DateTime? _httpDate(String? value) {
  if (value == null || value.length > 64) return null;
  final match = RegExp(
    r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value);
  if (match == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months.indexOf(match[2]!) + 1;
  final day = int.parse(match[1]!), year = int.parse(match[3]!);
  final hour = int.parse(match[4]!),
      minute = int.parse(match[5]!),
      second = int.parse(match[6]!);
  if (month == 0 ||
      day < 1 ||
      day > 31 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  final date = DateTime.utc(year, month, day, hour, minute, second);
  return date.month == month && date.day == day ? date : null;
}
