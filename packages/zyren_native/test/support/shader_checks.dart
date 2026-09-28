import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

const _compute = '@compute @workgroup_size(8, 4, 1) fn main() {}';

Future<void> verifyNativeShaders() async {
  final backend = await NativeBackend.create();
  final sibling = backend.createView();
  final foreign = await NativeBackend.create();
  try {
    expect(backend, isA<ShaderBackend>());
    final compiler = backend.createShaderCompiler(label: 'effects');
    final retainedOwner = sibling.createShaderCompiler(label: 'second view');
    const prefix = '// 🌍\n@compute @workgroup_size(1) fn main() { /* 🦀 */ ';
    final invalid = ShaderSource.wgsl('$prefix? }', label: 'weather.wgsl');
    await expectLater(
      compiler.compile(invalid),
      throwsA(
        isA<ShaderCompilationException>()
            .having((error) => error.source, 'source', same(invalid))
            .having(
              (error) => error.code,
              'code',
              ShaderErrorCode.invalidSource,
            )
            .having(
              (error) => error.issue.resourceLabel,
              'label',
              'weather.wgsl',
            )
            .having(
              (error) => error.diagnostics.first.location!.offset,
              'offset',
              prefix.length,
            )
            .having(
              (error) => error.diagnostics.first.location!.column,
              'column',
              prefix.split('\n').last.length + 1,
            ),
      ),
    );
    final original = await compiler.compile(
      ShaderSource.wgsl(_compute, label: 'first'),
    );
    final duplicate = await compiler.compile(
      ShaderSource.wgsl(_compute, label: 'second'),
    );
    expect(original.entryPoints.single.stage, ShaderStage.compute);
    expect(original.entryPoints.single.workgroupSize, (8, 4, 1));
    expect(duplicate.source.label, 'second');
    var stats = await backend.shaderStats();
    expect(stats.livePrograms, 2);
    expect(stats.cachedModules, 1);
    expect(stats.cacheHits, 1);
    expect(stats.residentSourceBytes, _compute.length * 2);
    await expectLater(
      foreign.createShaderCompiler().retain(original),
      throwsArgumentError,
    );
    final retained = await retainedOwner.retain(original);
    await backend.close();
    expect(original.isClosed, isTrue);
    expect(retained.isClosed, isFalse);
    stats = await sibling.shaderStats();
    expect(stats.livePrograms, 1);
    expect(stats.cachedModules, 1);
    await retainedOwner.close();
    stats = await sibling.shaderStats();
    expect(stats.livePrograms, 0);
    expect(stats.cachedModules, 0);
    expect(stats.residentSourceBytes, 0);
    final frame =
        await sibling.render(
              FrameSubmission.capture(
                scene: Scene()
                  ..add(
                    Mesh(
                      BoxGeometry(),
                      UnlitMaterial(color: const Color3(1, 0, 0)),
                    ),
                  ),
                camera: PerspectiveCamera(),
                size: PhysicalSize(31, 31),
              ),
            )
            as ReadbackOutput;
    final center = (15 * 31 + 15) * 4;
    expect(frame.image.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
  } finally {
    await backend.close();
    await sibling.close();
    await foreign.close();
  }
}

Future<void> verifyShaderCloseWhilePending() async {
  final backend = await NativeBackend.create();
  final sibling = backend.createView();
  try {
    final compiler = backend.createShaderCompiler();
    final pending = compiler.compile(ShaderSource.wgsl(_compute));
    final rejected = expectLater(pending, throwsStateError);
    await backend.close();
    await rejected;
    final stats = await sibling.shaderStats();
    expect(stats.livePrograms, 0);
    expect(stats.cachedModules, 0);
  } finally {
    await backend.close();
    await sibling.close();
  }
}
