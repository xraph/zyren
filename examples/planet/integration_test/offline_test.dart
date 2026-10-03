import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/layers/offline.dart';
import 'package:planet/main.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native offline download, cancellation, denial, retry and cold reopen',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'native-offline-lab-',
      );
      final key = GlobalKey<OfflineLabState>();
      OfflineLabState getState() => key.currentState!;
      Future<void> waitFor(bool Function() predicate) async {
        for (var i = 0; i < 400; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (getState().controller?.status.value case SceneFailed(
            :final issue,
          )) {
            fail('$issue');
          }
          if (predicate()) return;
        }
        fail(
          'Offline lab timed out: ${tester.widget<Text>(find.byKey(const Key('offline-status'))).data}',
        );
      }

      Future<void> waitReady() => waitFor(
        () =>
            getState().view != null &&
            getState().view!.geo.layers.snapshot.isNotEmpty &&
            getState().view!.geo.layers.layer('terrain').status.data ==
                GeoLayerDataState.ready,
      );
      try {
        await tester.binding.setSurfaceSize(const Size(1000, 700));
        await tester.pumpWidget(
          PlanetApp(
            home: OfflineLab(key: key, directory: directory),
          ),
        );
        await waitFor(() => find.text('Download region').evaluate().isNotEmpty);
        await tester.tap(find.byKey(const Key('download')));
        await waitFor(
          () => getState().repository!.job.progress.verifiedResources == 1,
        );
        await tester.tap(find.byKey(const Key('cancel')));
        await waitFor(() => find.text('Resume').evaluate().isNotEmpty);
        expect(
          getState().repository!.job.progress.state,
          GeoRegionJobState.paused,
        );
        await tester.tap(find.byKey(const Key('download')));
        await waitReady();
        expect(
          getState().repository!.job.progress.state,
          GeoRegionJobState.complete,
        );
        expect(getState().depth!.value, closeTo(105, 1e-8));
        await waitFor(
          () =>
              tester
                  .widget<FilterChip>(
                    find.widgetWithText(FilterChip, 'Deny source'),
                  )
                  .onSelected !=
              null,
        );
        await tester.tap(find.text('Deny source'));
        await tester.tap(find.byKey(const Key('download')));
        await waitFor(() => find.text('Retry').evaluate().isNotEmpty);
        expect(
          getState().repository!.job.progress.state,
          GeoRegionJobState.failed,
        );
        expect(
          getState().diagnostics!.failures.map((f) => f.code),
          everyElement(GeoDataError.denied),
        );
        await tester.tap(find.text('Deny source'));
        await tester.tap(find.byKey(const Key('download')));
        await waitReady();
        await waitFor(
          () =>
              tester
                  .widget<FilterChip>(
                    find.widgetWithText(FilterChip, 'Offline only'),
                  )
                  .onSelected !=
              null,
        );
        final attempts = getState().diagnostics!.transportAttempts;
        await tester.tap(find.text('Offline only'));
        await waitReady();
        expect(getState().diagnostics!.transportAttempts, attempts);
        for (final width in [390.0, 1000.0]) {
          await tester.binding.setSurfaceSize(Size(width, 700));
          getState().controller!.invalidate();
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byType(SceneView)).height,
            greaterThan(400),
          );
          expect(find.byKey(const Key('reopen')).hitTestable(), findsOneWidget);
        }
        await tester.tap(find.byKey(const Key('reopen')));
        await waitReady();
        expect(getState().offline, isTrue);
        await waitFor(
          () =>
              getState().diagnostics != null &&
              getState().diagnostics!.transportAttempts == 0,
        );
        expect(getState().depth!.value, closeTo(105, 1e-8));
        expect(getState().diagnostics!.tiers!.pinnedBytes, greaterThan(0));
        expect(getState().diagnostics!.physicalGpuResidentBytes, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        final state = key.currentState;
        await tester.pumpWidget(const SizedBox());
        await state?.shutdown();
        await directory.delete(recursive: true);
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
