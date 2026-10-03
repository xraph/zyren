import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/google_tiles_lab.dart';

void main() {
  testWidgets('cloud sparsity, density and animation fit desktop and phone', (
    tester,
  ) async {
    for (final width in [1000.0, 390.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pumpWidget(const GoogleTilesLabApp(clouds: true));
      final lab = tester.state<GoogleTilesLabState>(
        find.byType(GoogleTilesLab),
      );
      final density = find.byKey(const ValueKey('cloud-density'));
      final sparsity = find.byKey(const ValueKey('cloud-sparsity'));
      final animation = find.byKey(const ValueKey('cloud-animation'));
      expect(density, findsOneWidget);
      expect(sparsity, findsOneWidget);
      expect(animation, findsOneWidget);
      expect(tester.widget<Slider>(density).value, 1);
      expect(tester.widget<Slider>(sparsity).value, 0);
      expect(tester.widget<FilterChip>(animation).selected, true);
      await tester.tap(density);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(density).value, closeTo(.5, .06));
      expect(lab.profile.cloudDensity, closeTo(.5, .06));
      await tester.tap(sparsity);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(sparsity).value, closeTo(.5, .06));
      expect(lab.profile.cloudSparsity, closeTo(.5, .06));
      expect(lab.profile.cloudDensity, closeTo(.5, .06));
      await tester.tap(animation);
      await tester.pumpAndSettle();
      expect(tester.widget<FilterChip>(animation).selected, false);
      expect(lab.profile.cloudAnimationEnabled, false);
      await tester.tap(find.text('London'));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(density).value, closeTo(.5, .06));
      expect(tester.widget<Slider>(sparsity).value, closeTo(.5, .06));
      expect(tester.widget<FilterChip>(animation).selected, false);
      await tester.tap(find.byKey(const ValueKey('cloud-quality-low')));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(density).value, closeTo(.5, .06));
      expect(tester.widget<Slider>(sparsity).value, closeTo(.5, .06));
      expect(tester.widget<FilterChip>(animation).selected, false);
      expect(tester.takeException(), isNull);
      for (final invalid in [-.01, 1.01, double.nan, double.infinity]) {
        expect(() => lab.profile.cloudDensity = invalid, throwsArgumentError);
        expect(() => lab.profile.cloudSparsity = invalid, throwsArgumentError);
      }
      expect(lab.profile.cloudDensity, closeTo(.5, .06));
      expect(lab.profile.cloudSparsity, closeTo(.5, .06));
      await tester.pumpWidget(const SizedBox());
      await lab.whenClosed;
    }
    await tester.binding.setSurfaceSize(null);
  });
}
