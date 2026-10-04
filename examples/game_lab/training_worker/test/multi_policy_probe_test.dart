import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_game_lab_training_worker/policy_probe.dart';

void main() {
  test(
    'legacy structured request and receipt retain their original fields',
    () async {
      final file = File('../models/guard/model.json').absolute;
      final manifest = MlModelManifest.decode(await file.readAsString());
      final spec = TrainingProfiles.guard().spec;
      final decoder = ActionDecoder.characterDiscrete();
      final directory = await Directory.systemTemp.createTemp(
        'legacy-policy-probe-',
      );
      try {
        final input = File('${directory.path}/request.json');
        await input.writeAsString(
          jsonEncode({
            'manifest': file.path,
            'family': 'guard',
            'rows': [
              for (var i = 0; i < 2; i++)
                {
                  'reset': true,
                  'observation': List<double>.filled(spec.width, 0),
                  'legality': [
                    for (final branch in decoder.spec.branches)
                      [for (var i = 0; i < branch.choices.length; i++) i == 0],
                  ],
                },
            ],
          }),
        );
        Map<String, Object?>? receipt;
        await runPolicySequence(
          input.path,
          publish: (value) => receipt = value,
        );
        expect(receipt!.keys.toList(), [
          'schema_version',
          'model_sha256',
          'provider',
          'completed_runs',
          'live_sessions',
          'live_results',
          'outputs',
          'actions',
        ]);
        expect(receipt!['model_sha256'], manifest.sha256);
        expect(receipt!['completed_runs'], 2);
        expect(receipt!['live_sessions'], 0);
        expect(receipt!['live_results'], 0);
        expect(
          (receipt!['outputs'] as List)[0],
          (receipt!['outputs'] as List)[1],
        );
        expect(
          (receipt!['actions'] as List)[0],
          (receipt!['actions'] as List)[1],
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  final manifestPath = Platform.environment['MULTI_POLICY_MANIFEST'];
  test(
    'interleaved actors retain private recurrent carry and reset',
    () async {
      final file = File(manifestPath!);
      final manifest = MlModelManifest.decode(await file.readAsString());
      final profile = TrainingMultiProfiles.fromJson(
        (manifest.preprocessing['multiProfile'] as Map).cast<String, Object?>(),
      );
      const expectedHashes = {
        'cooperative-search':
            '340bba565cb0fb1ae8ab9b4feb78708ef4e2ff89315ce8ba79e23cc01f033e35',
        'competitive-pursuit':
            'dd745e4abda12dfde36d13f5bf3b229f3b08f71afb50b2ef0ca4edb6b8421fc5',
      };
      expect(manifest.sha256, expectedHashes[profile.task]);
      final directory = await Directory.systemTemp.createTemp(
        'multi-policy-probe-',
      );
      final rows = <Map<String, Object?>>[];
      for (var tick = 0; tick < 64; tick++) {
        for (final actor in ['a', 'b']) {
          final observation = List<double>.filled(profile.spec.width, 0);
          observation[26] = actor == 'a' ? 1 : -1;
          observation[0] = tick / 100;
          observation[3] = (tick % 2).toDouble();
          observation[16] = 1;
          rows.add({
            'actor': actor,
            'observation': observation,
            'reset': tick == 0 || actor == 'a' && tick == 32,
            'legality': [
              for (final branch in profile.decoder.spec.branches)
                [
                  for (var i = 0; i < branch.choices.length; i++)
                    branch.name == 'interact'
                        ? i == 0
                        : branch.name == 'jump'
                        ? i == (tick % 2)
                        : i == tick % branch.choices.length,
                ],
            ],
          });
        }
      }
      Future<Map<String, Object?>> probe(
        List<Map<String, Object?>> selected,
        String name,
      ) async {
        final input = File('${directory.path}/$name.json');
        await input.writeAsString(
          jsonEncode({
            'manifest': file.absolute.path,
            'family': profile.task,
            'rows': selected,
          }),
        );
        Map<String, Object?>? receipt;
        await runPolicySequence(
          input.path,
          publish: (value) => receipt = value,
        );
        expect(receipt!['live_sessions'], 0);
        expect(receipt!['live_results'], 0);
        expect(receipt!['completed_runs'], selected.length);
        return receipt!;
      }

      try {
        final both = await probe(rows, 'both');
        for (var i = 0; i < rows.length; i++) {
          final expected = [
            for (final mask in rows[i]['legality'] as List)
              (mask as List<bool>).indexOf(true),
          ];
          expect(((both['actions'] as List)[i] as Map)['discrete'], expected);
        }
        final before = const MlRuntime().diagnostics.completedRuns;
        final oversized = File('${directory.path}/oversized.json');
        await oversized.writeAsString(
          jsonEncode({
            'manifest': file.absolute.path,
            'family': profile.task,
            'rows': [
              for (var i = 0; i < 65; i++) {...rows.first, 'actor': 'actor-$i'},
            ],
          }),
        );
        await expectLater(runPolicySequence(oversized.path), throwsStateError);
        expect(const MlRuntime().diagnostics.completedRuns, before);
        expect(const MlRuntime().diagnostics.liveSessions, 0);
        final badMasks = File('${directory.path}/masks.json');
        final unsafe = Map<String, Object?>.from(rows.first);
        final masks = [
          for (final mask in unsafe['legality'] as List)
            List<bool>.from(mask as List),
        ];
        masks[4] = [true, true];
        unsafe['legality'] = masks;
        await badMasks.writeAsString(
          jsonEncode({
            'manifest': file.absolute.path,
            'family': profile.task,
            'rows': [unsafe],
          }),
        );
        await expectLater(runPolicySequence(badMasks.path), throwsStateError);
        expect(const MlRuntime().diagnostics.completedRuns, before);
        expect(const MlRuntime().diagnostics.liveSessions, 0);
        final tamperedManifest = File('${directory.path}/model.json');
        final tampered = jsonDecode(await file.readAsString()) as Map;
        final preprocessing = tampered['preprocessing'] as Map;
        (preprocessing['multiProfile'] as Map)['message_cadence_ticks'] = 6;
        await tamperedManifest.writeAsString(jsonEncode(tampered));
        final badProfile = File('${directory.path}/tampered.json');
        await badProfile.writeAsString(
          jsonEncode({
            'manifest': tamperedManifest.path,
            'family': profile.task,
            'rows': [rows.first],
          }),
        );
        await expectLater(
          runPolicySequence(badProfile.path),
          throwsFormatException,
        );
        expect(const MlRuntime().diagnostics.completedRuns, before);
        expect(const MlRuntime().diagnostics.liveSessions, 0);

        for (final actor in ['a', 'b']) {
          final indices = [
            for (var i = 0; i < rows.length; i++)
              if (rows[i]['actor'] == actor) i,
          ];
          final single = await probe([for (final i in indices) rows[i]], actor);
          for (var i = 0; i < indices.length; i++) {
            expect(
              (both['outputs'] as List)[indices[i]],
              (single['outputs'] as List)[i],
            );
            expect(
              (both['actions'] as List)[indices[i]],
              (single['actions'] as List)[i],
            );
          }
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: manifestPath == null
        ? 'Requires explicit unaccepted native multi candidate'
        : false,
  );
}
