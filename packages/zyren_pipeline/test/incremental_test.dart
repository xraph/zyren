import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import '../example/triangle_source.dart';

void main() {
  test('recipe options are deeply immutable and detached from caller data', () {
    final values = <Object?>[1];
    final step = PipelineTransform(
      sourceId: 'copy',
      uri: Uri.parse('memory:///copy'),
      tool: 'copy',
      toolVersion: '1',
      inputs: ['source'],
      options: {'values': values},
      run: (_) async => Uint8List(0),
    );
    values.add(2);
    expect(step.options['values'], [1]);
    expect(
      () => (step.options['values'] as List).add(3),
      throwsUnsupportedError,
    );
  });

  test(
    'restored receipts reuse transforms and propagate dependency changes',
    () async {
      final source = TriangleSource();
      final calls = <String>[];
      PipelineTransform step(
        String id,
        String dependency, {
        String version = '1',
        Map<String, Object?> options = const {},
      }) => PipelineTransform(
        sourceId: id,
        uri: Uri.parse('memory:///$id.bin'),
        tool: 'fixture-copy',
        toolVersion: version,
        inputs: [dependency],
        options: options,
        run: (context) async {
          calls.add(id);
          return context.inputs[dependency]!.bytes;
        },
      );
      final builder = PipelineIncrementalBuilder(
        PipelineBuilder(resolver: source),
      );
      final steps = [
        step('a', 'positions'),
        step('b', 'a'),
        step('metadata', 'model'),
      ];
      final first = await builder.build(
        sources: source.sources,
        transforms: steps,
        entrySourceId: 'model',
      );
      expect(first.built, ['a', 'b', 'metadata']);
      expect(first.bundle.processing, PipelineProcessing.derived);
      final persisted = PipelineBuildResult.restore(
        PipelineBundle.decode(first.bundle.encode()),
      );
      calls.clear();
      final second = await builder.build(
        sources: source.sources,
        transforms: steps.reversed.toList(),
        entrySourceId: 'model',
        previous: persisted,
      );
      expect(calls, isEmpty);
      expect(second.reused, ['a', 'b', 'metadata']);
      expect(second.bundle.encode(), first.bundle.encode());
      source.files[TriangleSource.bufferUri]![0] = 42;
      final changed = await builder.build(
        sources: source.sources,
        transforms: steps,
        entrySourceId: 'model',
        previous: second,
      );
      expect(changed.built, ['a', 'b']);
      expect(changed.reused, ['metadata']);
      calls.clear();
      final repinned = await builder.build(
        sources: source.sources,
        transforms: [
          step('a', 'positions', version: '2'),
          step('b', 'a'),
        ],
        entrySourceId: 'model',
        previous: changed,
      );
      expect(calls, ['a', 'b']);
      expect(
        repinned.bundle.resources.any((r) => r.source.sourceId == 'metadata'),
        isFalse,
      );
      final options = await builder.build(
        sources: source.sources,
        transforms: [
          step('a', 'positions', version: '2', options: {'quality': 50}),
          step('b', 'a'),
        ],
        entrySourceId: 'model',
        previous: repinned,
      );
      expect(options.built, ['a', 'b']);
    },
  );

  test(
    'cycles, unknown inputs and oversized output fail without changing previous build',
    () async {
      final source = TriangleSource();
      final builder = PipelineIncrementalBuilder(
        PipelineBuilder(resolver: source),
      );
      PipelineTransform step(String id, String input, {int size = 1}) =>
          PipelineTransform(
            sourceId: id,
            uri: Uri.parse('memory:///$id'),
            tool: 'fixture',
            toolVersion: '1',
            inputs: [input],
            run: (_) async => Uint8List(size),
          );
      await expectLater(
        builder.build(
          sources: source.sources,
          transforms: [step('a', 'b'), step('b', 'a')],
          entrySourceId: 'model',
        ),
        throwsArgumentError,
      );
      await expectLater(
        builder.build(
          sources: source.sources,
          transforms: [step('a', 'missing')],
          entrySourceId: 'model',
        ),
        throwsArgumentError,
      );
      final small = PipelineIncrementalBuilder(
        PipelineBuilder(
          resolver: source,
          limits: const PipelineLimits(maxSourceBytes: 1024),
        ),
      );
      await expectLater(
        small.build(
          sources: source.sources,
          transforms: [step('a', 'positions', size: 1025)],
          entrySourceId: 'model',
        ),
        throwsFormatException,
      );
    },
  );

  test('late transform result cannot publish after cancellation', () async {
    final source = TriangleSource();
    final cancellation = PipelineCancellation();
    final started = Completer<void>(), gate = Completer<void>();
    final future = PipelineIncrementalBuilder(PipelineBuilder(resolver: source))
        .build(
          sources: source.sources,
          entrySourceId: 'model',
          cancellation: cancellation,
          transforms: [
            PipelineTransform(
              sourceId: 'derived',
              uri: Uri.parse('memory:///derived'),
              tool: 'wait',
              toolVersion: '1',
              inputs: ['positions'],
              run: (context) async {
                started.complete();
                await gate.future;
                return Uint8List.fromList(utf8.encode('late'));
              },
            ),
          ],
        );
    final check = expectLater(future, throwsA(isA<LoadCancelled>()));
    await started.future;
    cancellation.cancel();
    gate.complete();
    await check;
  });
}
