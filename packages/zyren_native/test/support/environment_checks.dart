import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'frame_graph_checks.dart' show createFrameEffect;

HdrImageData constantEnvironment(double r, double g, double b) => HdrImageData(
  pixels: Float32List.fromList([r, g, b, 1, r, g, b, 1]),
  size: PhysicalSize(2, 1),
);

const smallEnvironment = EnvironmentQuality(
  specularWidth: 16,
  diffuseWidth: 16,
  brdfSize: 16,
  samples: 64,
);

HdrImageData directionalEnvironment() {
  const width = 128, height = 64;
  final pixels = Float32List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final n = direction(x, y, width, height);
      final i = (y * width + x) * 4;
      pixels[i] = .5 + .5 * n.x;
      pixels[i + 1] = .5 + .5 * n.y;
      pixels[i + 2] = .5 + .5 * n.z;
      pixels[i + 3] = 1;
    }
  }
  return HdrImageData(pixels: pixels, size: PhysicalSize(width, height));
}

Vec3 direction(int x, int y, int width, int height) {
  final phi = ((x + .5) / width - .5) * 2 * math.pi;
  final theta = (y + .5) / height * math.pi;
  return Vec3(
    math.cos(phi) * math.sin(theta),
    math.cos(theta),
    math.sin(phi) * math.sin(theta),
  );
}

double halfAt(ByteData data, int byteOffset) {
  final bits = data.getUint16(byteOffset, Endian.little);
  final exponent = (bits >> 10) & 31;
  final mantissa = bits & 1023;
  expect(bits >> 15, 0, reason: 'nonnegative radiance or BRDF factor');
  expect(exponent, lessThan(31), reason: 'finite half float');
  return exponent == 0
      ? mantissa * math.pow(2, -24).toDouble()
      : (1 + mantissa / 1024) * math.pow(2, exponent - 15);
}

void expectPixel(
  ReadbackOutput frame,
  List<int> expected, {
  double tolerance = 2,
}) {
  final center = (frame.image.size.width * frame.image.size.height ~/ 2) * 4;
  final actual = frame.image.pixels.sublist(center, center + 4);
  for (var i = 0; i < 4; i++) {
    expect(
      actual[i],
      closeTo(expected[i], tolerance),
      reason: '$actual vs $expected',
    );
  }
}

// Direct angular quadrature of the BRDF over incident light directions.
// Unlike the GPU bake, this does not sample GGX half-vectors or use its PDF.
(double, double) referenceBrdf(double nv, double roughness) {
  const zSteps = 256, phiSteps = 512;
  final vx = math.sqrt(1 - nv * nv), a2 = math.pow(roughness, 4);
  var scale = 0.0, bias = 0.0;
  for (var z = 0; z < zSteps; z++) {
    final nl = (z + .5) / zSteps, radial = math.sqrt(1 - nl * nl);
    final visibility =
        .5 /
        (nl * math.sqrt(a2 + (1 - a2) * nv * nv) +
            nv * math.sqrt(a2 + (1 - a2) * nl * nl));
    for (var p = 0; p < phiSteps; p++) {
      final phi = (p + .5) / phiSteps * 2 * math.pi;
      final hx = radial * math.cos(phi) + vx;
      final hy = radial * math.sin(phi), hz = nl + nv;
      final length = math.sqrt(hx * hx + hy * hy + hz * hz);
      final nh = hz / length, vh = (vx * hx + nv * hz) / length;
      final denominator = nh * nh * (a2 - 1) + 1;
      final weight =
          a2 / (math.pi * denominator * denominator) * visibility * nl;
      final fc = math.pow(1 - vh, 5);
      scale += (1 - fc) * weight;
      bias += fc * weight;
    }
  }
  final solidAngle = 2 * math.pi / (zSteps * phiSteps);
  return (scale * solidAngle, bias * solidAngle);
}

/// Analytic linear gradients have a Lambert convolution of .5 + normal / 3.
/// This checks every direction, including poles and the panorama seam.
Future<void> verifyEnvironment(NativeGpuBackend backend) async {
  final resources = backend.createResourceScope();
  final scene = Scene()..background = const Color3(0, 0, 0);
  final mesh = scene.add(
    Mesh(
      PlaneGeometry(width: 4, height: 4),
      StandardMaterial(
        baseColor: const Color3(1, 1, 1),
        metallic: 1,
        roughness: 0,
      ),
    ),
  );
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
  Future<ReadbackOutput> draw(
    Environment? environment, {
    CompiledGraph? graph,
  }) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(15, 15),
              environment: environment,
              graph: graph,
              colorPipeline: graph == null
                  ? ColorPipeline(toneMapping: ToneMapping.linear)
                  : null,
            ),
          )
          as ReadbackOutput;
  try {
    final map = await EnvironmentMap.fromEquirectangular(
      directionalEnvironment(),
      resources: resources,
      quality: const EnvironmentQuality(
        specularWidth: 64,
        diffuseWidth: 32,
        brdfSize: 32,
        samples: 512,
      ),
    );
    for (final (texture, mip, coefficient, tolerance) in [
      (map.diffuse, 0, 1 / 3, .025),
      (map.specular, 0, .5, .006),
      (map.specular, map.quality.specularMipLevels - 1, 1 / 3, .025),
    ]) {
      final retained = await resources.retain(texture);
      final descriptor = texture.descriptor as TextureDescriptor;
      final width = descriptor.width >> mip, height = descriptor.height >> mip;
      final bytes = ByteData.sublistView(
        await resources.readTexture(retained, mipLevel: mip),
      );
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final n = direction(x, y, width, height);
          final expected = [
            .5 + n.x * coefficient,
            .5 + n.y * coefficient,
            .5 + n.z * coefficient,
          ];
          for (var channel = 0; channel < 3; channel++) {
            expect(
              halfAt(bytes, (y * width + x) * 8 + channel * 2),
              closeTo(expected[channel], tolerance),
              reason: 'direction ($x,$y), mip $mip, channel $channel',
            );
          }
        }
      }
    }
    final lut = ByteData.sublistView(
      await resources.readTexture(await resources.retain(map.brdf)),
    );
    for (final (x, y) in [(8, 12), (21, 23), (30, 31)]) {
      final (scale, bias) = referenceBrdf(x / 31, y / 31);
      expect(halfAt(lut, (y * 32 + x) * 8), closeTo(scale, .012));
      expect(halfAt(lut, (y * 32 + x) * 8 + 2), closeTo(bias, .004));
    }
    expectPixel(await draw(Environment(map: map)), [188, 188, 255, 255]);
    final effect = await createFrameEffect(backend, 15, 15);
    final shaders = backend.createShaderCompiler();
    try {
      expectPixel(await draw(Environment(map: map), graph: effect), [
        0,
        188,
        188,
        255,
      ]);
      final custom = await shaders.compileMesh(
        ShaderSource.wgsl('''
${MeshShaderInterface.wgsl}
@vertex fn vertex(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> {
  return mesh.mvp * vec4(p, 1.);
}
@fragment fn fragment() -> @location(0) vec4<f32> {
  return meshColor(vec4(.125, .25, .5, 1.));
}
'''),
      );
      final standard = mesh.material;
      mesh.material = ShaderMaterial(custom);
      expectPixel(await draw(Environment(map: map), graph: effect), [
        188,
        240,
        225,
        255,
      ]);
      mesh.material = standard;
      await custom.close();
    } finally {
      await effect.close();
      await shaders.close();
    }
    final rotated = await draw(
      Environment(
        map: map,
        rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
      ),
    );
    expectPixel(rotated, [0, 188, 188, 255], tolerance: 10);
    expect(rotated.stats.uploadedBytes, 0);
    mesh.material = StandardMaterial(
      baseColor: const Color3(1, 1, 1),
      metallic: 1,
      roughness: 1,
    );
    final rough = await draw(Environment(map: map));
    expect(rough.image.pixels[450], lessThan(230));
    expect(rough.image.pixels[450], greaterThan(100));
    final zero = TextureMap(
      image: TextureImage.rgba(
        width: 1,
        height: 1,
        pixels: Uint8List.fromList([0, 0, 0, 255]),
        format: TextureFormat.rgba8Unorm,
      ),
    );
    mesh.material = StandardMaterial(
      baseColor: const Color3(1, 1, 1),
      metallic: 1,
      occlusionMap: zero,
      emissive: const Color3(.25, 0, 0),
    );
    expectPixel(await draw(Environment(map: map)), [137, 0, 0, 255]);
    mesh.material = StandardMaterial(baseColor: const Color3(1, 1, 1));
    expectPixel(await draw(null), [0, 0, 0, 255]);
  } finally {
    scene.remove(mesh);
    await draw(null);
    await resources.close();
  }
}
