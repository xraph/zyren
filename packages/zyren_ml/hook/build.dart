import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'runtime_target.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;
    final iosVersion = os == OS.iOS
        ? RuntimeTarget.iosDeploymentVersion(
            input.config.code.iOS.targetVersion,
            input.userDefines['ios_deployment_target'],
          )
        : null;
    final selected = RuntimeTarget.select(
      os,
      arch,
      iosSdk: os == OS.iOS ? input.config.code.iOS.targetSdk : null,
      iosVersion: iosVersion,
      androidApi: os == OS.android
          ? input.config.code.android.targetNdkApi
          : null,
    );
    final target = selected.key;
    final manifestUri = input.packageRoot.resolve(
      'native/runtime-manifest.json',
    );
    final manifest =
        jsonDecode(await File.fromUri(manifestUri).readAsString())
            as Map<String, dynamic>;
    final artifacts = manifest['artifacts'] as Map<String, dynamic>;
    final artifact = artifacts[target] as Map<String, dynamic>?;
    if (artifact == null) {
      throw UnsupportedError(
        'zyren_ml: no checksum-pinned ONNX Runtime SDK for $target. '
        'Choose a registered native target.',
      );
    }
    if (!selected.android &&
        !(selected.appleMobile && Platform.isMacOS) &&
        os.name != Platform.operatingSystem) {
      throw UnsupportedError(
        'zyren_ml: cross-OS packaging is not qualified ($target on ${Platform.operatingSystem}).',
      );
    }
    final source = input.packageRoot.resolve('native/src/zyren_ml.cc');
    final header = input.packageRoot.resolve('native/include/zyren_ml.h');
    output.dependencies.addAll([manifestUri, source, header]);
    final url = Uri.parse(artifact['url'] as String);
    final archiveName = url.pathSegments.last;
    final vendor = File.fromUri(
      input.packageRoot.resolve('native/vendor/$archiveName'),
    );
    final archive = vendor.existsSync()
        ? vendor
        : File.fromUri(input.outputDirectoryShared.resolve(archiveName));
    if (!archive.existsSync()) {
      final client = HttpClient();
      try {
        final request = await client.getUrl(url);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException(
            'ONNX Runtime download returned ${response.statusCode}',
            uri: url,
          );
        }
        final pending = File('${archive.path}.pending-$pid');
        var length = 0;
        final sink = pending.openWrite();
        try {
          await for (final bytes in response) {
            length += bytes.length;
            if (length > 400 * 1024 * 1024) {
              throw StateError('Runtime archive exceeds download budget.');
            }
            sink.add(bytes);
          }
        } finally {
          await sink.close();
        }
        await pending.rename(archive.path);
      } finally {
        client.close(force: true);
      }
    }
    final actualHash = await sha256.bind(archive.openRead()).first;
    if (actualHash.toString() != artifact['sha256']) {
      throw StateError(
        'zyren_ml: ONNX Runtime archive SHA256 mismatch for $target. Remove ${archive.path} and retry.',
      );
    }
    if (vendor.existsSync()) output.dependencies.add(vendor.uri);
    // Re-extract verified bytes on each hook run. Never trust a mutable SDK cache.
    final unpack = Directory.fromUri(input.outputDirectory.resolve('sdk/'));
    if (unpack.existsSync()) await unpack.delete(recursive: true);
    await unpack.create(recursive: true);
    final nested = artifact['nestedArchive'] as String?;
    final extract = await Process.run('tar', [
      '-xf',
      archive.path,
      '-C',
      unpack.path,
      ?nested,
    ]);
    if (extract.exitCode != 0) {
      throw StateError(
        'zyren_ml: runtime extraction failed: ${extract.stderr}',
      );
    }
    if (nested != null) {
      final embedded = File.fromUri(unpack.uri.resolve(nested));
      final embeddedHash = await sha256.bind(embedded.openRead()).first;
      if (embeddedHash.toString() != artifact['nestedSha256']) {
        throw StateError('zyren_ml: Apple runtime nested SHA256 differs.');
      }
      final extracted = await Process.run('tar', [
        '-xf',
        embedded.path,
        '-C',
        unpack.path,
      ]);
      if (extracted.exitCode != 0) {
        throw StateError(
          'zyren_ml: Apple framework extraction failed: ${extracted.stderr}',
        );
      }
    }
    final sdk = unpack.uri.resolve('${artifact['directory']}/');
    final includes = sdk
        .resolve('${artifact['include'] ?? 'include'}/')
        .toFilePath();
    if (selected.appleMobile) {
      // The official XCFramework contains static archives. Wrap the selected
      // device or simulator slice without changing the runtime version or API.
      await CBuilder.library(
        name: 'onnxruntime',
        assetName: 'onnxruntime',
        sources: ['native/src/ort_anchor.cc'],
        includes: [includes],
        language: Language.cpp,
        std: 'c++17',
        cppLinkStdLib: 'c++',
        flags: ['-F${sdk.toFilePath()}', '-mios-version-min=$iosVersion'],
        frameworks: ['onnxruntime', 'Foundation', 'CoreML'],
        linkModePreference: LinkModePreference.dynamic,
      ).run(input: input, output: output);
    } else {
      final runtimeSource = File.fromUri(
        sdk.resolve(artifact['library'] as String),
      );
      final runtime = await runtimeSource.copy(
        File.fromUri(
          input.outputDirectory.resolve(
            os == OS.windows
                ? 'onnxruntime.dll'
                : os == OS.macOS
                ? 'libonnxruntime.dylib'
                : 'libonnxruntime.so',
          ),
        ).path,
      );
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'onnxruntime',
          file: runtime.uri,
          linkMode: DynamicLoadingBundled(),
        ),
      );
    }
    await CBuilder.library(
      name: 'zyren_ml',
      assetName: 'src/native_bindings.dart',
      sources: ['native/src/zyren_ml.cc'],
      includes: ['native/include', includes],
      language: Language.cpp,
      std: 'c++17',
      flags: [if (os == OS.iOS) '-mios-version-min=$iosVersion'],
      cppLinkStdLib: os == OS.android
          ? 'c++_static'
          : os == OS.macOS || os == OS.iOS
          ? 'c++'
          : os == OS.linux
          ? 'stdc++'
          : null,
      linkModePreference: LinkModePreference.dynamic,
    ).run(input: input, output: output);
  });
}
