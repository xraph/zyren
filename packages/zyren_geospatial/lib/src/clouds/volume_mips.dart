import 'dart:math' as math;
import 'package:zyren/zyren.dart';

/// Average the complete linear volume on the GPU before distant sampling.
Future<void> generateCloudVolumeMips(
  GpuScope scope,
  GpuResource<Texture> texture,
) async {
  final descriptor = texture.descriptor as TextureDescriptor;
  if (descriptor.mipLevels < 2) return;
  final storageFormat = switch (descriptor.format) {
    TextureFormat.r32Float => 'r32float',
    TextureFormat.rgba8Unorm => 'rgba8unorm',
    TextureFormat.rgba16Float => 'rgba16float',
    _ => throw ArgumentError('Cloud volume mip format is unsupported.'),
  };
  final work = scope.createChild(label: 'cloud volume mip workspace');
  try {
    // Separate allocations satisfy graph feedback checks for every backend.
    final scratch = await work.resources.createTexture(
      TextureDescriptor(
        width: math.max(1, descriptor.width >> 1),
        height: math.max(1, descriptor.height >> 1),
        depth: math.max(1, descriptor.depth >> 1),
        mipLevels: descriptor.mipLevels - 1,
        dimension: TextureDimension.d3,
        format: descriptor.format,
        usage: {TextureUsage.sampled, TextureUsage.storage},
      ),
    );
    final program = await work.shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var source:texture_3d<f32>;
@group(0) @binding(1) var destination:texture_storage_3d<$storageFormat,write>;
@compute @workgroup_size(4,4,4) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let outSize=textureDimensions(destination);if(any(id>=outSize)){return;}
 let inSize=textureDimensions(source);let ratio=vec3<f32>(inSize)/vec3<f32>(outSize);
 let lo=vec3<f32>(id)*ratio;let hi=lo+ratio;
 var value=0.;
 for(var z=i32(floor(lo.z));z<i32(ceil(hi.z));z++){
  for(var y=i32(floor(lo.y));y<i32(ceil(hi.y));y++){
   for(var x=i32(floor(lo.x));x<i32(ceil(hi.x));x++){
    let p=vec3<i32>(x,y,z);let weight=max(vec3<f32>(0.),min(hi,vec3<f32>(p)+1.)-max(lo,vec3<f32>(p)));
    value+=textureLoad(source,clamp(p,vec3<i32>(0),vec3<i32>(inSize)-1),0).r*weight.x*weight.y*weight.z;
   }
  }
 }
 textureStore(destination,vec3<i32>(id),vec4<f32>(value/(ratio.x*ratio.y*ratio.z),0.,0.,1.));
}
''', label: 'cloud volume mip reduction'),
    );
    final copy = await work.shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var source:texture_3d<f32>;
@group(0) @binding(1) var destination:texture_storage_3d<$storageFormat,write>;
@compute @workgroup_size(4,4,4) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 if(any(id>=textureDimensions(destination))){return;}
 textureStore(destination,vec3<i32>(id),textureLoad(source,vec3<i32>(id),0));
}
''', label: 'cloud volume mip copy'),
    );
    final graph = await work.graphs.compile(
      GraphDescription(
        inputs: [texture, scratch],
        passes: [
          for (var level = 1; level < descriptor.mipLevels; level++) ...[
            ComputePassDescriptor(
              name: 'cloud volume mip $level',
              program: program,
              bindings: ShaderBindings([
                TextureBinding.sampled(0, texture, mipLevel: level - 1),
                TextureBinding.storage(1, scratch, mipLevel: level - 1),
              ]),
              reads: [texture],
              writes: [scratch],
              after: {if (level > 1) 'copy volume mip ${level - 1}'},
              workgroups: Workgroups(
                (math.max(1, descriptor.width >> level) + 3) ~/ 4,
                (math.max(1, descriptor.height >> level) + 3) ~/ 4,
                (math.max(1, descriptor.depth >> level) + 3) ~/ 4,
              ),
            ),
            ComputePassDescriptor(
              name: 'copy volume mip $level',
              program: copy,
              bindings: ShaderBindings([
                TextureBinding.sampled(0, scratch, mipLevel: level - 1),
                TextureBinding.storage(1, texture, mipLevel: level),
              ]),
              reads: [scratch],
              writes: [texture],
              after: {'cloud volume mip $level'},
              workgroups: Workgroups(
                (math.max(1, descriptor.width >> level) + 3) ~/ 4,
                (math.max(1, descriptor.height >> level) + 3) ~/ 4,
                (math.max(1, descriptor.depth >> level) + 3) ~/ 4,
              ),
            ),
          ],
        ],
      ),
    );
    await graph.execute();
  } finally {
    await work.close();
  }
}
