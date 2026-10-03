import 'package:hooks/hooks.dart';
import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    output.dependencies.add(
      input.packageRoot.resolve('native/vendor/miniaudio.h'),
    );
    output.dependencies.add(input.packageRoot.resolve('native/zyren_audio.c'));
    await CBuilder.library(
      name: 'zyren_audio',
      assetName: 'src/bindings.dart',
      sources: [
        os == OS.iOS ? 'native/zyren_audio_ios.m' : 'native/zyren_audio.c',
      ],
      language: os == OS.iOS ? Language.objectiveC : Language.c,
      libraries: os == OS.linux
          ? ['m', 'pthread', 'dl']
          : os == OS.android
          ? ['m', 'dl']
          : os == OS.iOS
          ? ['m', 'pthread', 'objc']
          : [],
      frameworks: os == OS.macOS || os == OS.iOS
          ? [
              'CoreAudio',
              'AudioToolbox',
              'CoreFoundation',
              if (os == OS.iOS) ...['Foundation', 'AVFoundation'],
            ]
          : [],
    ).run(input: input, output: output);
  });
}
