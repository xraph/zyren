import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'noise_wgsl.dart';
import 'noise_hash.dart';

enum CloudTextureKind { weather, shape, detail, turbulence }

/// A complete procedural texture with independent native ownership.
final class CloudTexture {
  final GpuScope _scope;
  final GpuResource<Texture> texture;
  final CloudTextureKind kind;
  final int size;
  CloudTexture._(this._scope, this.texture, this.kind, this.size);
  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();
}

/// Native compute generators for the source's periodic Perlin/Worley textures.
/// One generation is admitted at a time. Cancellation waits for submitted GPU
/// work before releasing its resources; completed textures belong to the caller.
final class CloudTextureGenerator {
  final GpuScope owner;
  bool _busy = false;
  CloudTextureGenerator(this.owner);
  Future<CloudTexture> generate(
    CloudTextureKind kind, {
    int? size,
    bool Function()? isCancelled,
  }) async {
    final volume =
        kind == CloudTextureKind.shape || kind == CloudTextureKind.detail;
    size ??= switch (kind) {
      CloudTextureKind.weather => 512,
      CloudTextureKind.shape => 128,
      CloudTextureKind.detail => 32,
      CloudTextureKind.turbulence => 128,
    };
    RangeError.checkValueInInterval(size, 1, volume ? 128 : 512, 'size');
    if (_busy) throw StateError('Cloud texture generation is already running.');
    void check() {
      if (owner.isClosed || (isCancelled?.call() ?? false)) {
        throw StateError('Cloud texture generation cancelled.');
      }
    }

    check();
    _busy = true;
    final scope = owner.createChild(label: 'cloud ${kind.name}');
    final work = scope.createChild(label: 'cloud generator workspace');
    try {
      final texture = await scope.resources.createTexture(
        TextureDescriptor(
          width: size,
          height: size,
          depth: volume ? size : 1,
          dimension: volume ? TextureDimension.d3 : TextureDimension.d2,
          format: volume ? TextureFormat.r32Float : TextureFormat.rgba8Unorm,
          usage: {
            TextureUsage.sampled,
            TextureUsage.storage,
            TextureUsage.copySource,
          },
        ),
      );
      check();
      final output = await work.resources.retain(texture);
      final uniform = await work.resources.createBuffer(
        BufferDescriptor(
          size: 16,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      // The source sin hash magnifies last-bit platform differences into cell
      // changes. Use the pinned original float evaluation for its integer lattice.
      final hashes = cloudNoiseHashes();
      final hash = await work.resources.createBuffer(
        BufferDescriptor(
          size: hashes.lengthInBytes,
          usage: {BufferUsage.storage, BufferUsage.copyDestination},
        ),
      );
      await work.resources.writeBuffer(hash, hashes);
      final dimension = volume ? '3d' : '2d';
      final format = volume ? 'r32float' : 'rgba8unorm';
      final coordinate = volume ? 'id' : 'id.xy';
      final point = volume
          ? 'vec3<f32>((vec2<f32>(id.xy)+.5)/f32($size),f32(id.z)/f32($size))'
          : 'vec3<f32>((vec2<f32>(id.xy)+.5)/f32($size),0.)';
      final value = volume
          ? 'vec4<f32>(${kind.name}(point),0.,0.,1.)'
          : '${kind.name}(point)';
      final program = await work.shaders.compile(
        ShaderSource.wgsl('''
$cloudNoiseWgsl
@group(0) @binding(0) var output:texture_storage_$dimension<$format,write>;
@group(0) @binding(1) var<uniform> batch:vec4<u32>;
@compute @workgroup_size(4,4,1) fn main(@builtin(global_invocation_id) local:vec3<u32>){
 let id=local+vec3<u32>(0u,0u,batch.x);
 if(any($coordinate>=textureDimensions(output))){return;}
 let point=$point;textureStore(output,vec${volume ? 3 : 2}<i32>($coordinate),$value);
}
''', label: 'cloud ${kind.name} generator'),
      );
      check();
      final graph = await work.graphs.compile(
        GraphDescription(
          inputs: [uniform, hash],
          passes: [
            ComputePassDescriptor(
              name: 'cloud ${kind.name}',
              program: program,
              bindings: ShaderBindings([
                TextureBinding.storage(0, output),
                BufferBinding.uniform(1, uniform),
                BufferBinding.storageRead(2, hash),
              ]),
              reads: [uniform, hash],
              writes: [output],
              workgroups: Workgroups(
                (size + 3) ~/ 4,
                (size + 3) ~/ 4,
                volume ? math.min(8, size) : 1,
              ),
            ),
          ],
        ),
      );
      for (var z = 0; z < (volume ? size : 1); z += 8) {
        check();
        await work.resources.writeBuffer(
          uniform,
          Uint32List.fromList([z, 0, 0, 0]),
        );
        await graph.execute();
        check();
      }
      await work.close();
      check();
      return CloudTexture._(scope, texture, kind, size);
    } catch (_) {
      await scope.close();
      rethrow;
    } finally {
      _busy = false;
    }
  }
}
