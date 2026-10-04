import 'package:zyren/zyren.dart';
import 'distance_fog.dart';

enum AerialNormalEncoding {
  /// Unit normal encoded as .5 * (normal + 1).
  rgb,

  /// Source octahedral encoding, with signed XY in [-1, 1]. Use a float texture.
  octahedral,
}

enum AerialNormalSpace { view, world }

/// One bounded non-air interval on each view ray, in camera-ray metres.
/// The left half of [transport] stores RGB transmittance and entry distance;
/// the right half stores RGB inscatter and exit distance. Equal entry and exit
/// means no medium. Maps use nearest sampling and must match the current view.
/// Scattering is unpremultiplied. Air is integrated on either side exactly once.
final class AerialMediumInputs {
  final GpuResource<Texture> transport;
  AerialMediumInputs({required this.transport}) {
    final d = transport.descriptor as TextureDescriptor;
    if (d.dimension != TextureDimension.d2 ||
        d.width.isOdd ||
        d.width < 2 ||
        !d.usage.contains(TextureUsage.sampled) ||
        (d.format != TextureFormat.rgba16Float &&
            d.format != TextureFormat.rgba32Float)) {
      throw ArgumentError(
        'Aerial medium transport needs a sampled float RGBA map with two equal horizontal halves.',
      );
    }
  }
}

/// Optional top-left screen maps. All maps use linear values and bilinear
/// sampling at normalized screen UVs, so their resolutions may differ.
/// Normal RGB zero bypasses relighting. Overlay RGB must be premultiplied by
/// alpha; the mask blends existing radiance (zero) with relit albedo (one).
/// Installation retains each map until replacement or controller disposal.
final class AerialPerspectiveInputs {
  final GeoDistanceFog? fog;
  final GpuResource<Texture>? normal, lightingMask, overlay;
  final AerialMediumInputs? medium;
  final AerialNormalEncoding normalEncoding;
  final AerialNormalSpace normalSpace;
  final int lightingMaskChannel;
  AerialPerspectiveInputs({
    this.fog,
    this.normal,
    this.medium,
    this.lightingMask,
    this.overlay,
    this.normalEncoding = AerialNormalEncoding.rgb,
    this.normalSpace = AerialNormalSpace.view,
    this.lightingMaskChannel = 0,
  }) {
    RangeError.checkValueInInterval(
      lightingMaskChannel,
      0,
      3,
      'lightingMaskChannel',
    );
    for (final texture in [normal, lightingMask, overlay]) {
      if (texture == null) continue;
      final d = texture.descriptor as TextureDescriptor;
      if (d.dimension != TextureDimension.d2 ||
          !d.usage.contains(TextureUsage.sampled) ||
          d.format == TextureFormat.rgba8UnormSrgb) {
        throw ArgumentError(
          'Aerial inputs require sampled linear 2D maps; normals and overlays require RGBA.',
        );
      }
    }
    for (final texture in [normal, overlay]) {
      if (texture != null &&
          (texture.descriptor as TextureDescriptor).format ==
              TextureFormat.r32Float) {
        throw ArgumentError('Aerial normals and overlays require RGBA.');
      }
    }
    if (normal != null &&
        normalEncoding == AerialNormalEncoding.octahedral &&
        (normal!.descriptor as TextureDescriptor).format ==
            TextureFormat.rgba8Unorm) {
      throw ArgumentError('Signed octahedral normals require a float texture.');
    }
    if (lightingMask != null &&
        lightingMaskChannel != 0 &&
        (lightingMask!.descriptor as TextureDescriptor).format ==
            TextureFormat.r32Float) {
      throw ArgumentError('A single-channel mask requires channel zero.');
    }
  }
}

/// Scope-owned copies allow a caller to close the original resource owner.
final class RetainedAerialInputs {
  final GpuScope scope;
  final AerialPerspectiveInputs value;
  RetainedAerialInputs._(this.scope, this.value);
  static Future<RetainedAerialInputs> retain(
    GpuScope parent,
    AerialPerspectiveInputs input,
  ) async {
    final scope = parent.createChild(label: 'aerial inputs');
    Future<GpuResource<Texture>?> keep(GpuResource<Texture>? value) async =>
        value == null ? null : await scope.resources.retain(value);
    try {
      final value = AerialPerspectiveInputs(
        fog: input.fog,
        normal: await keep(input.normal),
        medium: input.medium == null
            ? null
            : AerialMediumInputs(
                transport: await scope.resources.retain(
                  input.medium!.transport,
                ),
              ),
        lightingMask: await keep(input.lightingMask),
        overlay: await keep(input.overlay),
        normalEncoding: input.normalEncoding,
        normalSpace: input.normalSpace,
        lightingMaskChannel: input.lightingMaskChannel,
      );
      return RetainedAerialInputs._(scope, value);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}
