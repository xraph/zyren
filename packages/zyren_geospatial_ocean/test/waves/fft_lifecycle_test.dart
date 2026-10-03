import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

class OversizedSpectrum implements OceanSpectrumModel {
  @override
  String get id => 'oversized';
  @override
  int get version => 1;
  @override
  double energy(
    double kx,
    double kz,
    OceanWaveBand band, {
    double gravity = 9.81,
  }) => 1e70;
}

void main() {
  test(
    'failed native allocation and cancelled replacement preserve the published field',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final scope = GpuScope.fromBackend(backend);
      addTearDown(scope.close);
      final field = await OceanWaveFieldGpu.create(
        scope,
        fixtureSea(resolution: 32),
      );
      addTearDown(field.close);
      final original = await field.evaluate(1, resolution: 8);
      final before = await field.debugRead(original);
      final bytes = (await backend.resourceStats()).residentBytes;
      await backend.configureResourceBudget(16 * 1024 * 1024);
      final blocker = scope.resources.createChild();
      await blocker.createBuffer(
        BufferDescriptor(
          size: 16 * 1024 * 1024 - bytes - 20000,
          usage: {BufferUsage.copyDestination},
        ),
      );
      final pressuredBytes = (await backend.resourceStats()).residentBytes;
      await expectLater(
        field.evaluate(2, resolution: 32),
        throwsA(isA<ResourceException>()),
      );
      expect(field.current, same(original));
      expect(original.isCurrent, isTrue);
      expect(
        (await field.debugRead(original)).displacement,
        before.displacement,
      );
      expect((await backend.resourceStats()).residentBytes, pressuredBytes);
      await backend.configureResourceBudget(256 * 1024 * 1024);
      await blocker.close();
      final cancellation = LoadCancellationSource()..cancel();
      await expectLater(
        field.evaluate(2, resolution: 16, cancellation: cancellation),
        throwsA(isA<LoadCancelled>()),
      );
      expect(field.current, same(original));
      final during = LoadCancellationSource();
      final pending = field.evaluate(2, resolution: 16, cancellation: during);
      during.cancel();
      await expectLater(pending, throwsA(isA<LoadCancelled>()));
      expect(field.current, same(original));
      expect((await backend.resourceStats()).residentBytes, bytes);
      for (final size in [16, 4, 32, 8]) {
        await field.evaluate(2, resolution: size);
      }
      final finalSnapshot = field.current!;
      await field.close();
      expect(finalSnapshot.isCurrent, isFalse);
      expect(scope.childCount, 0);
      expect((await backend.resourceStats()).liveAllocations, 0);
      await expectLater(field.evaluate(3, resolution: 8), throwsStateError);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'close drains accepted evaluation and logical admission rejects replacement before allocation',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final scope = GpuScope.fromBackend(backend);
      addTearDown(scope.close);
      final field = await OceanWaveFieldGpu.create(
        scope,
        fixtureSea(resolution: 32),
        maxLogicalBytes: OceanWaveFieldGpu.estimateBytes(8, 1),
      );
      final before = await field.evaluate(0, resolution: 8);
      await expectLater(
        field.evaluate(1, resolution: 16),
        throwsA(isA<ResourceException>()),
      );
      expect(field.current, same(before));
      final pending = field.evaluate(2, resolution: 8);
      final closing = field.close();
      await expectLater(pending, throwsStateError);
      await closing;
      expect(scope.childCount, 0);
      expect((await backend.resourceStats()).liveAllocations, 0);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'unsupported model magnitude fails before publishing nonfinite native fields',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final scope = GpuScope.fromBackend(backend);
      addTearDown(scope.close);
      final state = OceanSeaState(
        seed: 42,
        canonicalResolution: 8,
        bands: fixtureSea().bands,
        spectrum: OversizedSpectrum(),
      );
      final field = await OceanWaveFieldGpu.create(scope, state);
      await expectLater(field.evaluate(0, resolution: 8), throwsArgumentError);
      expect(field.current, isNull);
      expect(field.logicalPayloadBytes, 0);
      expect((await backend.resourceStats()).liveAllocations, 0);
      await field.close();
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
