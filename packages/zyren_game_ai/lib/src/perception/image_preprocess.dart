part of '../../zyren_game_ai.dart';

/// Versioned RGB or RGB/depth profile. sRGB channel bytes remain sRGB before
/// affine normalization; depth is axial metres divided by maxMetres.
final class CameraProfile {
  final int width, height, cadenceTicks, latencyTicks;
  final bool depth;
  final List<double> mean, std;
  final double maxMetres, fieldOfView, near, far;
  final Vec3 offset;
  CameraProfile({
    this.width = 84,
    this.height = 84,
    this.depth = false,
    List<double> mean = const [0, 0, 0],
    List<double> std = const [1, 1, 1],
    this.maxMetres = 100,
    this.cadenceTicks = 1,
    this.latencyTicks = 1,
    this.fieldOfView = math.pi / 3,
    this.near = .1,
    this.far = 1000,
    this.offset = Vec3.zero,
  }) : mean = List.unmodifiable(mean),
       std = List.unmodifiable(std) {
    _bounded(width, 128, 'width');
    _bounded(height, 128, 'height');
    _bounded(cadenceTicks, 3600, 'cadenceTicks');
    _bounded(latencyTicks, 3600, 'latencyTicks');
    if (widthElements > 65536 ||
        mean.length != 3 ||
        std.length != 3 ||
        mean.any((v) => !v.isFinite || v.abs() > 100) ||
        std.any((v) => !v.isFinite || v < 1e-6 || v > 100) ||
        !far.isFinite ||
        far > 100000 ||
        !maxMetres.isFinite ||
        maxMetres <= 0 ||
        maxMetres > 100000 ||
        !offset.isFinite) {
      throw ArgumentError('Invalid camera normalization.');
    }
    PerspectiveCamera(fieldOfView: fieldOfView, near: near, far: far);
  }
  int get channels => depth ? 5 : 3;
  int get widthElements => width * height * channels;
  String get hash => _hash(toJson());
  Map<String, Object> toJson() => {
    'version': 1,
    'width': width,
    'height': height,
    'channels': depth ? 'RGBDV' : 'RGB',
    'layout': 'NCHW',
    'colorSpace': 'srgb',
    'normalization': '(byte/255-mean)/std',
    'mean': mean,
    'std': std,
    'depth': 'camera-axis-metres/maxMetres-clamped',
    'invalidDepth': 'zero-and-separate-mask',
    'depthCoverage': 'depth-writing-fragments; nearest-covered-MSAA-sample',
    'maxMetres': maxMetres,
    'cadenceTicks': cadenceTicks,
    'latencyTicks': latencyTicks,
    'fieldOfView': fieldOfView,
    'near': near,
    'far': far,
    'offset': offset.storage,
  };
  MlTensor preprocess(ImageData image, [DepthData? distances]) {
    if (image.size.width != width ||
        image.size.height != height ||
        image.colorSpace != ColorSpace.srgb ||
        image.format != PixelFormat.rgba8 ||
        depth &&
            (distances == null ||
                distances.size.width != width ||
                distances.size.height != height)) {
      throw ArgumentError(
        'Camera buffers do not match the normalization profile.',
      );
    }
    final count = width * height, values = Float32List(widthElements);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x, pixel = y * image.rowStride + x * 4;
        final alpha = image.pixels[pixel + 3] / 255;
        for (var c = 0; c < 3; c++) {
          var channel = image.pixels[pixel + c] / 255;
          if (image.alphaMode == AlphaMode.premultiplied) {
            channel = alpha == 0 ? 0 : (channel / alpha).clamp(0, 1);
          }
          values[c * count + i] = (channel - mean[c]) / std[c];
        }
        if (depth && distances!.validity[i] == 1) {
          values[3 * count + i] = (distances.metres[i] / maxMetres).clamp(0, 1);
          values[4 * count + i] = 1;
        }
      }
    }
    return MlTensor.float32([1, channels, height, width], values);
  }
}

/// Selects only the registered camera reading from a permitted observation frame.
/// Sensor profile and identity are pinned in the encoder ID and policy contract.
final class CameraPolicyEncoder implements PolicyObservationEncoder {
  final CameraProfile profile;
  final String sensorId;
  CameraPolicyEncoder(this.profile, {this.sensorId = 'camera'}) {
    _name(sensorId);
  }
  @override
  String get id => 'camera-tensor-v1:${_hash([sensorId, profile.hash])}';
  @override
  MlTensor encode(ObservationFrame frame) {
    final readings = frame.readings
        .where((reading) => reading.sensorId == sensorId)
        .toList();
    if (readings.length != 1 ||
        readings.single.state != SensorState.known ||
        readings.single.configurationHash != profile.hash ||
        readings.single.tick != frame.tick ||
        readings.single.values.length != profile.widthElements) {
      throw StateError('Camera observation unavailable or mismatched.');
    }
    final reading = readings.single, count = profile.width * profile.height;
    for (var i = 0; i < reading.values.length; i++) {
      if ((i < count * 3 || i >= count * 4) && reading.validity[i] != 1) {
        throw StateError('Camera color or validity channels unavailable.');
      }
      if (profile.depth &&
          i >= count * 3 &&
          i < count * 4 &&
          (reading.validity[i] == 0 && reading.values[i] != 0 ||
              reading.values[i + count] != reading.validity[i])) {
        throw StateError('Camera depth mask mismatch.');
      }
    }
    return MlTensor.float32([
      1,
      profile.channels,
      profile.height,
      profile.width,
    ], reading.values);
  }
}
