// The worker is a development entry point, so the package lists it under
// dev_dependencies.
// ignore: depend_on_referenced_packages
import 'package:zyren_game_lab_training_worker/worker.dart';

Future<void> main(List<String> args) => runTrainingWorker(args);
