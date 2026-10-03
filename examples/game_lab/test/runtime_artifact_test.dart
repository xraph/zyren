import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_game_lab/game_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline exported games repeatedly release their native runtime before presentation',
    () async {
      for (final name in ['exploration', 'vehiclePlayground']) {
        final bytes = await File('games/$name.zygame').readAsBytes();
        for (var i = 0; i < 10; i++) {
          final game = await GameLabSession.load(bytes);
          final world = game.runtime.world!;
          expect(world.isClosed, isFalse);
          expect(game.scene.objects.containsKey('player'), isTrue);
          await game.close();
          await game.close();
          expect(world.isClosed, isTrue);
          expect(game.runtime.world, isNull);
        }
      }
    },
  );
  test('invalid bundle rejects before creating a game session', () async {
    await expectLater(
      GameLabSession.load(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<Exception>()),
    );
  });
}
