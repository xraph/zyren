part of 'engine.dart';

/// Logical texture roles for one effect's previous and current frame. Use these
/// only in graph declarations; the engine swaps their physical bindings.
final class TextureHistory {
  final GpuResource<Texture> previous, current;
  final GpuResource<Buffer> uniforms;
  TextureHistory._(this.previous, this.current, this.uniforms);

  /// Bind [uniforms] as a uniform buffer. Ignore previous pixels when validFrames
  /// is zero. Generation changes on invalidation, without clearing GPU textures.
  static const wgsl = '''
struct TextureHistoryState {
  validFrames: u32,
  generation: u32,
  _padding: vec2<u32>,
};
''';
}

final class _HistoryCandidate {
  final ResourceScope scope;
  final textures = <TextureHistory>[];
  GpuResource<Buffer>? uniforms;
  Future<GpuResource<Buffer>>? _allocatingUniforms;
  _HistoryCandidate(this.scope);

  Future<GpuResource<Buffer>> _createUniforms() async =>
      uniforms = await scope.createBuffer(
        BufferDescriptor(
          label: 'frame history state',
          size: 16,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );

  Future<TextureHistory> create(
    PhysicalSize size,
    TextureFormat format,
    String label,
    Set<TextureUsage> usage,
  ) async {
    if (!usage.contains(TextureUsage.sampled) ||
        !usage.any(
          {TextureUsage.renderAttachment, TextureUsage.storage}.contains,
        )) {
      throw GraphException(
        GraphErrorCode.invalidDescriptor,
        'History textures require sampled and renderAttachment or storage usage.',
      );
    }
    final info = await (_allocatingUniforms ??= _createUniforms());
    Future<GpuResource<Texture>> texture(String role) => scope.createTexture(
      TextureDescriptor(
        label: '$label $role',
        width: size.width,
        height: size.height,
        format: format,
        usage: usage,
      ),
    );
    final previous = await texture('previous');
    final current = await texture('current');
    final history = TextureHistory._(previous, current, info);
    textures.add(history);
    return history;
  }

  Future<void> writeState(int frames, int generation) async {
    if (uniforms == null) return;
    final bytes = ByteData(16)
      ..setUint32(0, frames, Endian.little)
      ..setUint32(4, generation, Endian.little);
    await scope.writeBuffer(uniforms!, bytes);
  }

  Future<void> close() => scope.close();
}
