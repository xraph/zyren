import 'dart:io';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    output.dependencies.addAll([
      input.packageRoot.resolve('native/Cargo.toml'),
      input.packageRoot.resolve('native/Cargo.lock'),
      input.packageRoot.resolve('native/rust-toolchain.toml'),
      input.packageRoot.resolve('native/src/lib.rs'),
    ]);
    final vendor = Directory.fromUri(
      input.packageRoot.resolve('native/vendor/'),
    );
    await for (final file in vendor.list(recursive: true, followLinks: false)) {
      if (file is File) output.dependencies.add(file.uri);
    }
    await RustBuilder(
      assetName: 'src/bindings.dart',
    ).run(input: input, output: output);
  });
}
