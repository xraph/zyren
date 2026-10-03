/// Host-selected file publication. External commands cannot supply paths.
library;

import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

final class GameFilePublisher {
  final File destination;
  static int _sequence = 0;
  GameFilePublisher(this.destination);
  Future<void> publish(
    PipelineBundle bundle,
    LoadCancellation cancellation,
    void Function() checkBeforeCommit,
  ) async {
    cancellation.throwIfCancelled();
    checkBeforeCommit();
    final path = destination.absolute.path;
    final temporary = File('$path.build-$pid-${++_sequence}.tmp');
    try {
      await destination.parent.create(recursive: true);
      cancellation.throwIfCancelled();
      checkBeforeCommit();
      await temporary.writeAsBytes(bundle.encode(), flush: true);
      cancellation.throwIfCancelled();
      checkBeforeCommit();
      await temporary.rename(path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
