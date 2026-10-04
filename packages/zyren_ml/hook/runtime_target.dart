import 'package:code_assets/code_assets.dart';

/// Archive paths and platform minima for the checksum-pinned native runtime.
final class RuntimeTarget {
  final String key;
  final bool android, appleMobile;
  const RuntimeTarget(
    this.key, {
    this.android = false,
    this.appleMobile = false,
  });

  /// Flutter currently sends a fixed iOS15 hook minimum. A host can explicitly
  /// declare its real deployment target; compilation must use that same value.
  static int? iosDeploymentVersion(int? hookVersion, Object? declared) {
    if (declared == null) return hookVersion;
    if (declared is! int ||
        declared < 16 ||
        declared > 99 ||
        (hookVersion != null && declared < hookVersion)) {
      throw ArgumentError(
        'zyren_ml: ios_deployment_target must be an integer '
        'from16..99 and cannot lower the hook deployment target.',
      );
    }
    return declared;
  }

  static RuntimeTarget select(
    OS os,
    Architecture arch, {
    IOSSdk? iosSdk,
    int? iosVersion,
    int? androidApi,
  }) {
    if (os == OS.android) {
      if (androidApi == null || androidApi < 24) {
        throw UnsupportedError('zyren_ml requires Android API24 or newer.');
      }
      if (![
        Architecture.arm,
        Architecture.arm64,
        Architecture.ia32,
        Architecture.x64,
      ].contains(arch)) {
        throw UnsupportedError('zyren_ml: unsupported Android ABI $arch.');
      }
      return RuntimeTarget('${os.name}-${arch.name}', android: true);
    }
    if (os == OS.iOS) {
      if (iosVersion == null || iosVersion < 16) {
        throw UnsupportedError(
          'zyren_ml requires an iOS16 or newer deployment target (ORT binary minimum15.1).',
        );
      }
      final simulator = iosSdk == IOSSdk.iPhoneSimulator;
      if (iosSdk == null ||
          (!simulator && arch != Architecture.arm64) ||
          (simulator &&
              ![Architecture.arm64, Architecture.x64].contains(arch))) {
        throw UnsupportedError(
          'zyren_ml: unsupported Apple mobile SDK/architecture.',
        );
      }
      return RuntimeTarget(
        'ios-${arch.name}${simulator ? '-simulator' : ''}',
        appleMobile: true,
      );
    }
    return RuntimeTarget('${os.name}-${arch.name}');
  }
}
