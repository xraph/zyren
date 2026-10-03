import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_pipeline/preparation.dart';
import '../example/preparation_fixture.dart';

void main() {
  test(
    'prepared LOD and compressed texture match native reference pixels',
    () async {
      final worker = PipelinePreparer(
        executable: File(
          'packages/zyren_pipeline/native/target/debug/zyren_pipeline_prepare',
        ).absolute.path,
      );
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final geometry = grid();
      final original = geometry.capture();
      final prepared = await worker.mesh(
        geometry: original,
        sourceId: 'grid',
        ratio: .25,
        maxError: .001,
      );
      final texture = await worker.texture(
        rgba: checkerPixels(),
        width: 16,
        height: 16,
        srgb: true,
        decoder: NativeTextureDecoder.forDevice(backend.capabilities),
      );
      final fallback = await const NativeTextureDecoder().decode(
        texture.ktx2,
        encoding: TextureEncoding.ktx2Basis,
      );
      var mesh = Mesh(geometry, UnlitMaterial(color: Color3.hex(0xff8800)));
      final scene = Scene()..add(mesh);
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      Future<ReadbackOutput> render() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(96, 96),
                ),
              )
              as ReadbackOutput;
      final reference = await render();
      scene.remove(mesh);
      mesh = Mesh(BufferGeometry.fromData(prepared.geometry), mesh.material);
      scene.add(mesh);
      final lod = await render();
      expect(lod.image.pixels, reference.image.pixels);
      mesh.material = UnlitMaterial(
        colorMap: TextureMap(image: TextureImage.fromData(texture.decoded)),
      );
      final compressed = await render();
      mesh.material = UnlitMaterial(
        colorMap: TextureMap(image: TextureImage.fromData(fallback)),
      );
      final rgba = await render();
      var maximum = 0;
      for (var y = 35; y < 61; y++) {
        for (var x = 35; x < 61; x++) {
          for (var c = 0; c < 4; c++) {
            final index = (y * 96 + x) * 4 + c;
            final error =
                (compressed.image.pixels[index] - rgba.image.pixels[index])
                    .abs();
            if (error > maximum) maximum = error;
          }
        }
      }
      expect(maximum, lessThanOrEqualTo(12));
      print(
        'backend=${backend.capabilities.backend} adapter=${backend.capabilities.adapterName} '
        'target=${texture.decoded.descriptor.format.name} triangles=${original.primitiveCount}->${prepared.geometry.indices.length ~/ 3} '
        'quadricError=${prepared.absoluteError} lodPixelError=0 texturePixelError=$maximum',
      );
    },
    skip:
        Platform.environment['RUN_NATIVE_GPU'] != '1' ||
        Platform.environment['RUN_PIPELINE_PREPARATION'] != '1',
  );
}
