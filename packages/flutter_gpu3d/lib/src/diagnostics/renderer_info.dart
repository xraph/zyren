import 'package:gpu3d/rendering.dart';

class RendererInfo {
  final String backend;
  final String? adapterName;
  final String? driverDescription;
  final DeviceCapabilities capabilities;
  final PresentationPath presentationPath;
  Set<int> get sampleCounts => capabilities.limits.sampleCounts;
  const RendererInfo({
    required this.backend,
    required this.adapterName,
    required this.capabilities,
    required this.presentationPath,
    this.driverDescription,
  });
}
