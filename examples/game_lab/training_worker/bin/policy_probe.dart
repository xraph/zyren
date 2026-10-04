import 'dart:io';
import 'package:zyren_game_lab_training_worker/policy_probe.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--policy-sequence') {
    stderr.writeln('Usage: policy_probe --policy-sequence <request.json>');
    exitCode = 64;
    return;
  }
  try {
    await runPolicySequence(arguments[1]);
  } catch (error) {
    stderr.writeln('Native policy sequence failed: $error');
    exitCode = 1;
  }
}
