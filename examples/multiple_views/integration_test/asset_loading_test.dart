import 'package:flutter/widgets.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/rendering.dart';
import 'package:integration_test/integration_test.dart';

class CountedBundle implements ByteSourceResolver {
  var reads = 0;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) {
    reads++;
    return const FlutterSourceResolver().read(uri, context);
  }
}

class ImageTemplate {
  final BufferGeometry geometry;
  final TextureImage image;
  var released = false;
  ImageTemplate(this.geometry, this.image);
  Mesh instantiate() {
    if (released) throw StateError('Template was released.');
    return Mesh(
      geometry,
      UnlitMaterial(
        colorMap: TextureMap(
          image: image,
          sampler: const SamplerDescriptor(
            minFilter: TextureFilter.nearest,
            magFilter: TextureFilter.nearest,
          ),
        ),
      ),
    );
  }
}

class ImageLoader extends AssetLoader<ImageTemplate> {
  var decodes = 0;
  @override
  Future<DecodedAsset<ImageTemplate>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    decodes++;
    final pixels = await context.decodeImage(source.bytes, fieldPath: 'image');
    final geometry = PlaneGeometry(width: 2, height: 2);
    final image = TextureImage.fromImage(pixels);
    return DecodedAsset(
      create: () => ImageTemplate(geometry, image),
      release: (template) => template.released = true,
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'shared bundle decode keeps native instances alive after template release',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final resolver = CountedBundle(), loader = ImageLoader();
      final services = AssetServices(
        resolver: resolver,
        imageDecoder: const NativeImageDecoder(),
      );
      final firstScope = AssetScope(services: services),
          secondScope = AssetScope(services: services);
      final request = AssetRequest(
        uri: Uri.parse('asset:///assets/images/corners.png'),
        loader: loader,
      );
      final firstTask = firstScope.load(request),
          secondTask = secondScope.load(request);
      final templates = await Future.wait([
        firstTask.result,
        secondTask.result,
      ]);
      expect(resolver.reads, 1);
      expect(loader.decodes, 1);
      final scene = Scene()..add(templates[0].instantiate());
      final other = Scene()..add(templates[1].instantiate());
      expect(templates[0], isNot(same(templates[1])));
      final backend = await NativeBackend.create(),
          second = backend.createView();
      FrameSubmission capture(Scene value) => FrameSubmission.capture(
        scene: value,
        camera: PerspectiveCamera(position: const Vec3(0, 0, 2)),
        size: PhysicalSize(64, 64),
      );
      try {
        final frames = await Future.wait([
          backend.render(capture(scene)),
          second.render(capture(other)),
        ]);
        final pixels = (frames[0] as ReadbackOutput).image.pixels;
        expect(pixels.sublist((20 * 64 + 20) * 4, (20 * 64 + 20) * 4 + 4), [
          255,
          0,
          0,
          255,
        ]);
        expect(
          frames.fold(0, (sum, frame) => sum + frame.stats.uploadedBytes),
          200,
        );
        firstScope.release(templates[0]);
        expect(templates[0].instantiate, throwsStateError);
        expect(templates[1].instantiate(), isA<Mesh>());
        await firstScope.close();
        final retained = await backend.render(capture(scene)) as ReadbackOutput;
        expect(retained.image.pixels, pixels);
        expect(retained.stats.uploadedBytes, 0);
        await backend.close();
        await secondScope.close();
        final survivor = await second.render(capture(other)) as ReadbackOutput;
        expect(survivor.image.pixels, pixels);
        expect(survivor.stats.uploadedBytes, 0);
        await second.render(capture(Scene()));
        expect((await second.resourceStats()).residentBytes, 0);
      } finally {
        await firstScope.close();
        await secondScope.close();
        await backend.close();
        await second.close();
      }
    },
  );
}
