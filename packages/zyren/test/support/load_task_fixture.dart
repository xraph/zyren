import 'package:zyren/zyren.dart';
import 'package:zyren/src/assets/pending_load_task.dart';

LoadTask<T> pendingLoadTask<T>(Future<T> result) => PendingLoadTask<T>(result);
