import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('two native sessions share a scene and close independently', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    await tester.pumpWidget(const MultipleViewsApp());
    Future<void> waitUntil(bool Function() ready) async {
      for (var attempt = 0; attempt < 120; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (ready()) return;
      }
      fail('Native views did not finish the expected frame.');
    }

    List<RawImage> images() =>
        tester.widgetList<RawImage>(find.byType(RawImage)).toList();
    await waitUntil(
      () =>
          images().length == 2 &&
          images().every((image) => image.image != null),
    );
    final controllers = tester
        .widgetList<SceneView>(find.byType(SceneView))
        .map((view) => view.controller!)
        .toList();
    expect(controllers[0].scene, same(controllers[1].scene));
    final rightCamera = controllers[1].camera.position;
    var leftImage = images()[0].image;
    final rightImage = images()[1].image;
    await tester.tap(find.text('Move left camera'));
    await waitUntil(() => !identical(images()[0].image, leftImage));
    expect(controllers[1].camera.position, rightCamera);
    expect(images()[1].image, same(rightImage));
    await tester.binding.reassembleApplication();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widgetList<SceneView>(find.byType(SceneView)).first.controller,
      same(controllers[0]),
    );
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close left view'));
    await waitUntil(() => images().length == 1);
    await controllers[0].whenDisposed;
    expect(controllers[1].isDisposed, isFalse);
    // Let the remaining view finish its new layout before testing an idle edit.
    await tester.pump(const Duration(milliseconds: 500));
    leftImage = images().single.image;
    await tester.tap(find.text('Turn mesh'));
    await waitUntil(() => !identical(images().single.image, leftImage));
    await tester.tap(find.text('Open left view'));
    await waitUntil(
      () =>
          images().length == 2 &&
          images().every((image) => image.image != null),
    );
    expect(tester.takeException(), isNull);
    final reopened = tester
        .widgetList<SceneView>(find.byType(SceneView))
        .first
        .controller!;
    expect(reopened, isNot(same(controllers[0])));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
    await Future.wait([reopened.whenDisposed, controllers[1].whenDisposed]);
    await tester.binding.setSurfaceSize(null);
  });
}
