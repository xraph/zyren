import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/geospatial_scene.dart';
import 'package:planet/google_tiles_lab.dart';

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
        tester.widget<DropdownButton<MoonlightSelection>>(lighting).value,
        MoonlightSelection.visible,
      );
      final daytime = lab.profile.date;
      await tester.tap(night);
      await tester.pumpAndSettle();
      expect(lab.profile.nightView, true);
      expect(lab.profile.date, isNot(daytime));
      await tester.tap(lighting);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Natural').last);
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
      await tester.tap(lighting);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Off').last);
      await tester.pumpAndSettle();
      expect(lab.profile.moonlight, MoonlightSelection.off);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await lab.whenClosed;
    }
    await tester.binding.setSurfaceSize(null);
  });
}
