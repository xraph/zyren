import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/src/assets/pending_load_task.dart';

LoadTask<T> pendingLoadTask<T>(Future<T> result) => PendingLoadTask<T>(result);
