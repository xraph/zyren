import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    output.dependencies.addAll([
      input.packageRoot.resolve('native/Cargo.toml'),
      input.packageRoot.resolve('native/build.rs'),
      input.packageRoot.resolve('native/vendor/mikktspace/mikktspace.c'),
      input.packageRoot.resolve('native/vendor/mikktspace/mikktspace.h'),
      input.packageRoot.resolve('native/src/interop/apple_buffer.mm'),
      input.packageRoot.resolve('native/Cargo.lock'),
      input.packageRoot.resolve('native/vendor/wgpu-hal/Cargo.toml'),
      input.packageRoot.resolve('native/rust-toolchain.toml'),
    ]);
    await RustBuilder(
      assetName: 'src/bindings.dart',
    ).run(input: input, output: output);
  });
}
