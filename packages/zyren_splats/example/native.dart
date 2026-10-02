import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_splats/zyren_splats.dart';

/// Saves linear premultiplied RGB on black as a portable pixmap.
Future<void> main(List<String> args) async {
  final backend = await NativeBackend.create(),
      data = GaussianCloudData(
        sourceUri: Uri.parse('memory:Gaussian-example'),
        sourceVersion: 'fixture-1',
        splats: [
          GaussianSplat(
            mean: const Vec3(-.15, 0, 1),
            covariance: GaussianCovariance(xx: .08, xy: .025, yy: .02, zz: .01),
            color: const Color3(1, .15, .03),
            opacity: .8,
          ),
          GaussianSplat(
            mean: const Vec3(.15, 0, -1),
            covariance: GaussianCovariance(
              xx: .02,
              xy: -.015,
              yy: .08,
              zz: .01,
            ),
            color: const Color3(.03, .35, 1),
            opacity: .8,
          ),
        ],
      );
  final owner = GpuScope.fromBackend(backend);
  try {
    final renderer = await GaussianSplatRenderer.create(owner, data);
    final image = await renderer.render(
      camera: OrthographicCamera(),
      size: PhysicalSize(256, 256),
    );
    final output = args.isEmpty ? 'gaussians.ppm' : args.single;
    File(output).writeAsBytesSync([
      ...ascii.encode('P6\n256 256\n255\n'),
      for (var i = 0; i < image.pixels.length; i += 4)
        ...image.pixels.sublist(i, i + 3),
    ]);
    await renderer.close();
    print(
      '${backend.capabilities.backend}: saved $output; ${(await backend.resourceStats()).residentBytes} resident frame bytes.',
    );
  } finally {
    await owner.close();
    await backend.close();
  }
}
