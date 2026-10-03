import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game/io.dart';
import 'save_replay_test.dart' as fixture;

void main() {
  test(
    'disk restart and failed publication preserve previous save and discard stages',
    () async {
      final directory = await Directory.systemTemp.createTemp('game-save-');
      final session = fixture.game()..step();
      try {
        final store = FileGameSaveStore(directory: directory, slot: 'one');
        await store.write(session.save());
        final before = (await store.read())!.encode();
        session.step();
        final failed = FileGameSaveStore(
          directory: directory,
          slot: 'one',
          beforePublish: (_) async => throw StateError('interrupted'),
        );
        await expectLater(failed.write(session.save()), throwsStateError);
        await File(
          '${directory.path}/.one.stage-crash.tmp',
        ).writeAsString('partial');
        final reopened = FileGameSaveStore(directory: directory, slot: 'one');
        expect((await reopened.read())!.encode(), before);
        expect(
          await File('${directory.path}/.one.stage-crash.tmp').exists(),
          isFalse,
        );
        await reopened.write(session.save());
        expect((await reopened.read())!.tick, 2);
      } finally {
        await session.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
