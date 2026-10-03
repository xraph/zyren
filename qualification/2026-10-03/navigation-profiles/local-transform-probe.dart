import 'dart:convert';
import 'package:zyren/zyren.dart';

void main() {
  final objects = List.generate(
    1000,
    (i) => Group()..position = Vec3(i.toDouble(), 2, 3),
  );
  double checksum = 0;
  for (var warmup = 0; warmup < 100; warmup++) {
    for (final object in objects) {
      checksum += object.localMatrix.storage[12];
    }
  }
  final durations = <int>[];
  for (var repeat = 0; repeat < 5; repeat++) {
    final clock = Stopwatch()..start();
    for (var frame = 0; frame < 2000; frame++) {
      for (final object in objects) {
        checksum += object.localMatrix.storage[12];
      }
    }
    durations.add(clock.elapsedMicroseconds);
  }
  print(
    jsonEncode({
      'scope': 'AOT unchanged local matrix reads only, not navigation FPS',
      'objects': objects.length,
      'readsPerRepeat': 2000000,
      'microseconds': durations,
      'checksum': checksum,
    }),
  );
}
