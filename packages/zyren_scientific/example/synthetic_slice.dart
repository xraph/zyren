import 'dart:convert';
import 'dart:io';

import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_scientific/zyren_scientific.dart';

import 'support/png.dart';

/// Native readback example. Every value comes from the stated synthetic formula.
Future<void> main(List<String> args) async {
  final output = Directory(
    args.isEmpty ? '/tmp/zyren-scientific-evidence' : args.single,
  );
  await output.create(recursive: true);
  final field = syntheticField();
  final transfer = ScalarTransferFunction(
    unit: field.valueUnit,
    minimum: 273.15,
    maximum: 313.15,
    stops: [
      TransferStop(0, const Color3(0, 0, .8)),
      TransferStop(.5, const Color3(0, .8, .5)),
      TransferStop(1, const Color3(1, .15, 0)),
    ],
  );
  final slice = ScalarSlice.build(
    grid: field,
    transfer: transfer,
    axis: SliceAxis.z,
    index: 1.5,
    coordinateTolerance: 1e-6,
  );
  final scene = Scene()..background = const Color3(.02, .025, .035);
  final view = ScientificSliceView(
    id: 'synthetic-temperature',
    scene: scene,
    slice: slice,
    coordinateTolerance: 1e-6,
  );
  final camera = OrthographicCamera(
    position: const Vec3(.5, .5, 5),
    target: const Vec3(.5, .5, 0),
    left: -.65,
    right: .65,
    bottom: -.65,
    top: .65,
  );
  final backend = await NativeBackend.create();
  try {
    final frame =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(640, 640),
              ),
            )
            as ReadbackOutput;
    final path = '${output.path}/synthetic-temperature-slice.png';
    await File(path).writeAsBytes(png(frame.image));
    final evidence = {
      'label':
          'SYNTHETIC DATA: formula fixture, not a measurement or solver result',
      ...view.describe(),
      'native': {
        'backend': backend.capabilities.backend,
        'adapter': backend.capabilities.adapterName,
        'drawCalls': frame.stats.drawCalls,
        'triangles': frame.stats.triangles,
        'readbackBytes': frame.stats.readbackBytes,
        'presentation': frame.stats.presentationPath.name,
        'viewportPresentationVerified': false,
      },
      'image': path,
    };
    await File(
      '${output.path}/synthetic-temperature-slice.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    stdout.writeln('SYNTHETIC DATA: temperature in K, coordinates in m.');
    stdout.writeln(
      'Formula: T = 273.15 + 20*x + 10*y + 5*z. Central samples are missing.',
    );
    stdout.writeln('${backend.capabilities.backend}: $path');
    stdout.writeln(
      '${slice.renderedCells} cells, ${slice.omittedCells} omitted, ${slice.maxCoordinateError} m local coordinate error.',
    );
  } finally {
    view.dispose();
    await backend.close();
  }
}

ScalarGrid3D syntheticField() {
  const nx = 41, ny = 41, nz = 4;
  return ScalarGrid3D(
    sizeX: nx,
    sizeY: ny,
    sizeZ: nz,
    values: [
      for (var k = 0; k < nz; k++)
        for (var j = 0; j < ny; j++)
          for (var i = 0; i < nx; i++)
            i >= 17 && i <= 23 && j >= 17 && j <= 23
                ? null
                : 273.15 + 20 * i / 40 + 10 * j / 40 + 5 * k,
    ],
    origin: Vec3.zero,
    spacing: const Vec3(.025, .025, 1),
    valueUnit: ScientificUnit(quantity: 'temperature', symbol: 'K'),
    coordinateUnit: ScientificUnit(quantity: 'length', symbol: 'm'),
    source: ScientificSource(
      id: 'synthetic:affine-temperature:v1',
      description:
          'Synthetic T(x,y,z) = 273.15 + 20*x + 10*y + 5*z, with a missing center column.',
      kind: ScientificDataKind.synthetic,
    ),
    name: 'Synthetic temperature',
  );
}
