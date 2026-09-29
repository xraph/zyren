import 'dart:io';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'support/animation_checks.dart';
import 'support/additive_animation_checks.dart';
import 'support/animation_transition_checks.dart';

void main() {
  test('crossfades match native skin and morph reference poses', () async {
    final backend = await NativeBackend.create();
    try {
      await verifyAnimationTransitions(backend);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test('additive layers match explicit native skin and morph poses', () async {
    final backend = await NativeBackend.create();
    try {
      await verifyAdditiveAnimation(backend);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test(
    'animated native poses preserve instance isolation and frozen captures',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyAnimation(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
