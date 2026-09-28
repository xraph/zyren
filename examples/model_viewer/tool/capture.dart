import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:model_viewer/model_bounds.dart';

/// Explicit native GPU readback for a standalone PNG, without a Flutter window.
Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'Usage: dart run tool/capture.dart model.glb output.png [animationSeconds]',
    );
    exitCode = 64;
    return;
  }
  final uri = Uri.tryParse(args[0]);
  final source = uri != null && uri.hasScheme
      ? uri
      : File(args[0]).absolute.uri;
  final assets = AssetScope(
    services: const AssetServices(
      resolver: NativeSourceResolver(),
      imageDecoder: NativeImageDecoder(),
      tangentGenerator: NativeTangentGenerator(),
    ),
  );
  final backend = await NativeBackend.create();
  try {
    final model = await assets.load(Gltf.uri(source)).result;
    final root = model.instantiate();
    if (args.length == 3) {
      final seconds = double.parse(args[2]);
      root.mixer
          .play(root.animations.first)
          .seek(Duration(microseconds: (seconds * 1e6).round()));
    }
    final bounds = await modelBounds(root, () => false);
    final scene = Scene()
      ..background = const Color3(.025, .04, .065)
      ..add(root);
    final camera = PerspectiveCamera(
      target: bounds.center,
      position:
          bounds.center +
          const Vec3(4, 3, 5).normalized() * bounds.radius * 3.8,
      near: bounds.radius / 1000,
      far: bounds.radius * 100,
    );
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(800, 600),
              ),
            )
            as ReadbackOutput;
    File(args[1]).writeAsBytesSync(png(output.image));
    stdout.writeln(
      'Saved ${args[1]} from native GPU readback: '
      '${output.stats.drawCalls} draws, ${output.stats.triangles} triangles.',
    );
  } finally {
    await assets.close();
    await backend.close();
  }
}

Uint8List png(ImageData image) {
  final width = image.size.width, height = image.size.height;
  final rows = Uint8List((width * 4 + 1) * height);
  for (var y = 0; y < height; y++) {
    rows.setRange(
      y * (width * 4 + 1) + 1,
      (y + 1) * (width * 4 + 1),
      image.pixels,
      y * image.rowStride,
    );
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = Uint8List.fromList([...ascii.encode(type), ...data]);
    var crc = 0xffffffff;
    for (final byte in body) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >>> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
      }
    }
    output.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    output.add(body);
    output.add(
      (ByteData(4)..setUint32(0, (~crc) & 0xffffffff)).buffer.asUint8List(),
    );
  }

  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', zlib.encode(rows));
  chunk('IEND', const []);
  return output.toBytes();
}
