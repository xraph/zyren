part of '../zyren_timeline.dart';

/// A named moment in a clip. Equal-time markers keep declaration order.
final class TimelineMarker {
  final Duration time;
  final String id;
  final String? label;
  TimelineMarker(this.time, {required this.id, this.label}) {
    if (time.isNegative || id.trim().isEmpty) {
      throw ArgumentError('Markers need a nonnegative time and nonempty ID.');
    }
  }
}

/// An immutable notification about a completed playback advance.
final class TimelineEvent {
  final TimelineMarker marker;

  /// Zero-based loop number. An explicit seek resets the count.
  final int loopIndex;

  /// Sampled clip position after the advance, which may pass [marker]'s time.
  final Duration position;
  const TimelineEvent._(this.marker, this.loopIndex, this.position);
}

extension on SceneTimelinePlugin {
  int _afterMarker(Duration time, List<TimelineMarker> ordered) {
    var low = 0, high = ordered.length;
    while (low < high) {
      final middle = low + ((high - low) ~/ 2);
      if ((reverse ? duration - ordered[middle].time : ordered[middle].time) <=
          time) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  List<TimelineEvent> _crossedEvents(
    Duration previous,
    Duration next,
    int wraps,
    int cycle, {
    required bool includeStart,
  }) {
    if (markers.isEmpty) return const [];
    final ordered = reverse ? _reverseMarkers : markers;
    final logicalPrevious = reverse ? duration - previous : previous;
    final logicalNext = reverse ? duration - next : next;
    final start = includeStart && logicalPrevious == Duration.zero
        ? 0
        : _afterMarker(logicalPrevious, ordered);
    final finish = _afterMarker(logicalNext, ordered);
    final edges = wraps == 0 ? finish - start : markers.length - start + finish;
    // Check division before multiplication to avoid overflow for tiny clips.
    if (edges > maxEventsPerAdvance ||
        (wraps > 1 &&
            wraps - 1 > (maxEventsPerAdvance - edges) ~/ markers.length)) {
      throw StateError(
        'Playback would exceed maxEventsPerAdvance ($maxEventsPerAdvance).',
      );
    }
    final result = <TimelineEvent>[];
    void append(int first, int last, int index) {
      for (var i = first; i < last; i++) {
        result.add(TimelineEvent._(ordered[i], index, next));
      }
    }

    if (wraps == 0) {
      append(start, finish, cycle);
    } else {
      append(start, markers.length, cycle);
      for (var i = 1; i < wraps; i++) {
        append(0, markers.length, cycle + i);
      }
      append(0, finish, cycle + wraps);
    }
    return result;
  }
}

List<TimelineMarker> _reverseMarkerOrder(List<TimelineMarker> markers) {
  final indexed = [for (var i = 0; i < markers.length; i++) (i, markers[i])];
  indexed.sort((a, b) {
    final order = b.$2.time.compareTo(a.$2.time);
    return order == 0 ? a.$1.compareTo(b.$1) : order;
  });
  return List.unmodifiable([for (final entry in indexed) entry.$2]);
}
