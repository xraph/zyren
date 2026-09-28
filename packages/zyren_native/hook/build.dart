import 'dart:io';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    output.dependencies.addAll([
      input.packageRoot.resolve('native/Cargo.toml'),
      input.packageRoot.resolve('native/build.rs'),
      input.packageRoot.resolve('native/src/interop/apple_buffer.mm'),
      input.packageRoot.resolve('native/Cargo.lock'),
      input.packageRoot.resolve('native/vendor/wgpu-hal/Cargo.toml'),
      input.packageRoot.resolve('native/rust-toolchain.toml'),
    ]);
    await RustBuilder(
      assetName: 'src/bindings.dart',
      // Apply the deployment floor to transitive C++ codecs as well as our
      // interop source. cc otherwise defaults to the installed SDK version.
      extraCargoEnvironmentVariables: {
        'MACOSX_DEPLOYMENT_TARGET':
            Platform.environment['MACOSX_DEPLOYMENT_TARGET'] ?? '11.0',
        'IPHONEOS_DEPLOYMENT_TARGET':
            Platform.environment['IPHONEOS_DEPLOYMENT_TARGET'] ?? '13.0',
      },
    ).run(input: input, output: output);
  });
}
