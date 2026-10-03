import 'lab_test_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/google_tiles_lab.dart';
import 'package:planet/geospatial_presets.dart';
import 'package:planet/geospatial_device_profile.dart';
import 'package:planet/rendering_choices.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  testWidgets('cloud quality selector works before a renderer attaches', (
    tester,
  ) async {
    for (final width in [1000.0, 390.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pumpWidget(const GoogleTilesLabApp(clouds: true));
      await openLabControls(tester);
      final lab = tester.state<GoogleTilesLabState>(
        find.byType(GoogleTilesLab),
      );
      final control = find.byKey(const ValueKey('cloud-quality'));
      expect(control, findsOneWidget);
      await tapLabControl(
        tester,
        find.byKey(const ValueKey('cloud-quality-ultra')),
      );
      await tester.pumpAndSettle();
      expect(lab.profile.cloudQuality.preset, CloudQualityPreset.ultra);
      final shadows = find.byKey(const ValueKey('cloud-shadows'));
      final shadowQuality = find.byKey(const ValueKey('cloud-shadow-quality'));
      await tapLabControl(
        tester,
        find.byKey(const ValueKey('cloud-shadow-quality-low')),
      );
      await tester.pumpAndSettle();
      expect(lab.profile.cloudQuality.shadowPreset, CloudQualityPreset.low);
      expect(lab.profile.cloudQuality.preset, CloudQualityPreset.ultra);
      await tapLabControl(tester, shadows);
      await tester.pumpAndSettle();
      expect(lab.profile.cloudQuality.shadowsEnabled, false);
      expect(
        tester
            .widget<RenderingChoices<CloudQualitySelection>>(shadowQuality)
            .onChanged,
        isNull,
      );
      await tapLabControl(
        tester,
        find.byKey(const ValueKey('cloud-quality-auto')),
      );
      await tester.pumpAndSettle();
      expect(
        lab.profile.cloudQuality.preset,
        lab.deviceProfile.clouds().preset,
      );
      expect(lab.profile.cloudQuality.shadowsEnabled, false);
      expect(lab.profile.cloudQuality.shadowPreset, CloudQualityPreset.low);
      await tapLabControl(tester, shadows);
      await tester.pumpAndSettle();
      expect(lab.profile.cloudQuality.shadowsEnabled, true);
      expect(lab.profile.cloudQuality.shadowPreset, CloudQualityPreset.low);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await lab.whenClosed;
    }
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets(
    'a selected cloud story initializes its camera and date together',
    (tester) async {
      await tester.pumpWidget(
        const GoogleTilesLabApp(
          clouds: true,
          initialPreset: GoogleTilesPreset.london,
        ),
      );
      final lab = tester.state<GoogleTilesLabState>(
        find.byType(GoogleTilesLab),
      );
      expect(lab.preset, GoogleTilesPreset.london);
      expect(
        lab.profile.air.date,
        GoogleTilesPreset.london.utcDate(year: 2026),
      );
      expect(lab.profile.date, lab.profile.air.date);
      expect(
        lab.controller.camera.position.distanceTo(lab.controller.camera.target),
        closeTo(GoogleTilesPreset.london.distance, 1e-6),
      );
      await tester.pumpWidget(const SizedBox());
      await lab.whenClosed;
    },
  );
  testWidgets('missing access keeps a compact actionable state without a GPU', (
    tester,
  ) async {
    for (final width in [1000.0, 390.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pumpWidget(const GoogleTilesLabApp());
      await openLabControls(tester);
      await tester.pump();
      expect(find.byType(ZeroState), findsOneWidget);
      expect(find.text('Google Maps access is required'), findsOneWidget);
      expect(find.text('Check access'), findsOneWidget);
      expect(find.text('Manhattan'), findsOneWidget);
      expect(find.text('Fuji'), findsOneWidget);
      await tapLabControl(tester, find.text('Fuji'));
      await tester.pump();
      final lab = tester.state<GoogleTilesLabState>(
        find.byType(GoogleTilesLab),
      );
      expect(lab.preset, GoogleTilesPreset.fuji);
      expect(lab.controller.scene.renderSettings.toneMapping, ToneMapping.agx);
      expect(lab.controller.scene.renderSettings.exposure, 10);
      expect(lab.profile.date, GoogleTilesPreset.fuji.utcDate(year: 2026));
      expect(
        lab.controller.camera.position.distanceTo(lab.controller.camera.target),
        closeTo(7000, 1e-6),
      );
      await tapLabControl(tester, find.text('Manhattan'));
      await tester.pump();
      expect(lab.preset, GoogleTilesPreset.manhattan);
      expect(
        lab.controller.camera.position.distanceTo(lab.controller.camera.target),
        closeTo(3000, 1e-6),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('panel-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check access'));
      await tester.pump();
      expect(find.text('Google Maps access is required'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
    await tester.binding.setSurfaceSize(null);
  });
}
