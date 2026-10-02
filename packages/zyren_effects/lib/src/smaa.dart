import 'package:zyren/zyren.dart';
import 'smaa_tables.dart';
import 'smaa_wgsl.dart';

enum SmaaPreset { low, medium, high, ultra }

/// Source color-based SMAA with diagonal and corner detection in high/ultra.
/// Rebuild for a new viewport size, then replace the attachment before closing
/// the previous owner. You can inspect both intermediate maps through a lease.
final class SmaaEffect {
  final GpuScope _scope;
  final List<ScreenEffect> stages;
  final GpuResource<Texture> edges, weights;
  SmaaEffect._(this._scope, List<ScreenEffect> stages, this.edges, this.weights)
    : stages = List.unmodifiable(stages);
  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();
  void _validate() {
    if (isClosed || stages.any((e) => e.isClosed)) {
      throw StateError('SMAA owner has closed.');
    }
  }

  SmaaAttachment attach(Scene scene, {int order = 200}) {
    _validate();
    RangeError.checkValueInInterval(order, -32768, 32765, 'order');
    if (scene.effects.length + 3 > 32) {
      throw StateError('SMAA exceeds the scene effect limit.');
    }
    return SmaaAttachment._([
      for (var i = 0; i < 3; i++) scene.addEffect(stages[i], order: order + i),
    ]);
  }

  static Future<SmaaEffect> create(
    GpuScope owner,
    PhysicalSize size, {
    SmaaPreset preset = SmaaPreset.medium,
  }) async {
    if (size.width > 2048 ||
        size.height > 2048 ||
        size.width * size.height > 2097152) {
      throw ArgumentError(
        'SMAA viewport exceeds 2048 per axis or 2097152 pixels.',
      );
    }
    final scope = owner.createChild(label: 'SMAA');
    try {
      Future<GpuResource<Texture>> target() => scope.resources.createTexture(
        TextureDescriptor(
          width: size.width,
          height: size.height,
          format: TextureFormat.rgba16Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.renderAttachment,
            TextureUsage.copySource,
          },
        ),
      );
      Future<GpuResource<Texture>> table(bool area) async {
        final image = await scope.resources.createTexture(
          TextureDescriptor(
            width: area ? 160 : 64,
            height: area ? 560 : 16,
            format: TextureFormat.rgba8Unorm,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await scope.resources.writeTexture(image, smaaTable(area));
        return image;
      }

      final edges = await target(),
          weights = await target(),
          area = await table(true),
          search = await table(false);
      Future<ScreenEffect> pass(
        String source, {
        GpuResource<Texture>? target,
        List<ShaderBinding> bindings = const [],
      }) async => scope.materials.compileEffect(
        PostProcessDescriptor(
          program: await scope.shaders.compile(
            ShaderSource.wgsl(source, label: 'SMAA'),
          ),
          stage: PostProcessStage.display,
          target: target,
          bindings: ShaderBindings(bindings),
        ),
      );
      final stages = <ScreenEffect>[
        await pass(
          smaaEdgesWgsl([.15, .1, .1, .05][preset.index]),
          target: edges,
        ),
        await pass(
          smaaWeightsWgsl(
            [4, 8, 16, 32][preset.index],
            [0, 0, 8, 16][preset.index],
          ),
          target: weights,
          bindings: [
            TextureBinding.sampled(0, edges, group: 1),
            TextureBinding.sampled(1, area, group: 1),
            TextureBinding.sampled(2, search, group: 1),
          ],
        ),
        await pass(
          smaaBlendWgsl,
          bindings: [TextureBinding.sampled(0, weights, group: 1)],
        ),
      ];
      return SmaaEffect._(scope, stages, edges, weights);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}

/// Owns the three scene slots, independently of the effect's GPU resources.
final class SmaaAttachment {
  final List<EffectRegistration> _slots;
  SmaaAttachment._(this._slots);
  bool get isDisposed => _slots.first.isDisposed;
  void replace(SmaaEffect candidate) {
    if (isDisposed) throw StateError('SMAA attachment has closed.');
    candidate._validate();
    for (var i = 0; i < 3; i++) {
      _slots[i].replace(candidate.stages[i]);
    }
  }

  void dispose() {
    for (final slot in _slots) {
      slot.dispose();
    }
  }
}
