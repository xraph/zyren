import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/geospatial_scene.dart';
import 'package:planet/google_tiles_lab.dart';
import 'package:planet/rendering_choices.dart';

void main() {
  testWidgets('moonlight and night view fit narrow and desktop cloud labs', (
    tester,
  ) async {
    for (final width in [1000.0, 390.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pumpWidget(const GoogleTilesLabApp(clouds: true));
      final lab = tester.state<GoogleTilesLabState>(
        find.byType(GoogleTilesLab),
      );
      final lighting = find.byKey(const ValueKey('moonlight'));
      final night = find.byKey(const ValueKey('night-view'));
      expect(
        tester.widget<RenderingChoices<MoonlightSelection>>(lighting).selected,
        MoonlightSelection.visible,
      );
      expect(lab.profile.air.maxStarResolution, greaterThanOrEqualTo(1920));
      final daytime = lab.profile.date;
      expect(lab.profile.starIntensity, 1000);
      await tester.tap(night);
      await tester.pumpAndSettle();
      expect(lab.profile.nightView, true);
      expect(lab.profile.starIntensity, 50000);
      expect(lab.profile.date, isNot(daytime));
      await tester.tap(find.byKey(const ValueKey('moonlight-natural')));
      await tester.pumpAndSettle();
      expect(lab.profile.moonlight, MoonlightSelection.natural);
      await tester.tap(find.text('London'));
      await tester.pumpAndSettle();
      expect(lab.profile.moonlight, MoonlightSelection.natural);
      expect(lab.profile.nightView, true);
      expect(tester.widget<FilterChip>(night).selected, true);
      await tester.tap(night);
      await tester.pumpAndSettle();
      expect(lab.profile.date, lab.preset.utcDate(year: 2026));
      expect(lab.profile.starIntensity, 1000);
      await tester.tap(find.byKey(const ValueKey('moonlight-off')));
      await tester.pumpAndSettle();
      expect(lab.profile.moonlight, MoonlightSelection.off);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await lab.whenClosed;
    }
    await tester.binding.setSurfaceSize(null);
  });
}
