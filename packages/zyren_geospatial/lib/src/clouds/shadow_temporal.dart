import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'frame.dart';
import 'quality.dart';
import 'media_wgsl.dart';
import 'temporal_wgsl.dart';

/// Temporal Beer maps keep each cascade's filtering inside its atlas tile.
final class CloudShadowTemporal {
  final GpuScope scope;
  final GpuResource<Texture> output;
  final GpuResource<Buffer> uniform;
  final CompiledGraph graph;
  CloudFrameState? _previous, _pending;
  CloudShadowTemporal._(this.scope, this.output, this.uniform, this.graph);
  static Future<CloudShadowTemporal> build(
    GpuScope owner,
    GpuResource<Texture> raw,
    GpuResource<Buffer> media,
    GpuResource<Buffer> frame,
    CloudQuality quality,
  ) async {
    final scope = owner.createChild(label: 'cloud shadow history');
    try {
      final descriptor = raw.descriptor as TextureDescriptor;
      Future<GpuResource<Texture>> map() => scope.resources.createTexture(
        TextureDescriptor(
          width: descriptor.width,
          height: descriptor.height,
          format: TextureFormat.rgba32Float,
          usage: {
            TextureUsage.storage,
            TextureUsage.sampled,
            TextureUsage.copySource,
          },
        ),
      );
      final output = await map(), history = await map();
      final uniform = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 272,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final shader = await scope.shaders.compile(
        ShaderSource.wgsl(
          cloudFrameWgsl +
              cloudMediaMathWgsl(quality) +
              cloudVarianceWgsl +
              _resolve,
          label: 'cloud shadow temporal resolve',
        ),
      );
      final copy = await scope.shaders.compile(
        ShaderSource.wgsl(_copy, label: 'cloud shadow history publication'),
      );
      final graph = await scope.graphs.compile(
        GraphDescription(
          inputs: [raw, media, frame, uniform, history],
          passes: [
            ComputePassDescriptor(
              name: 'shadow temporal resolve',
              program: shader,
              bindings: ShaderBindings([
                BufferBinding.uniform(0, media, group: 2),
                BufferBinding.uniform(5, frame, group: 2),
                BufferBinding.uniform(8, uniform, group: 2),
                TextureBinding.sampled(0, raw, group: 1),
                TextureBinding.sampled(1, history, group: 1),
                TextureBinding.storage(0, output, group: 3),
              ]),
              reads: [raw, media, frame, uniform, history],
              writes: [output],
              workgroups: Workgroups(
                (descriptor.width + 7) ~/ 8,
                (descriptor.height + 7) ~/ 8,
              ),
            ),
            ComputePassDescriptor(
              name: 'shadow history publication',
              program: copy,
              bindings: ShaderBindings([
                TextureBinding.sampled(0, output, group: 1),
                TextureBinding.storage(0, history, group: 3),
              ]),
              reads: [output],
              writes: [history],
              workgroups: Workgroups(
                (descriptor.width + 7) ~/ 8,
                (descriptor.height + 7) ~/ 8,
              ),
            ),
          ],
        ),
      );
      return CloudShadowTemporal._(scope, output, uniform, graph);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  Future<void> render(CloudFrameState state, {required bool valid}) async {
    final previous = _previous;
    final matrices = [
      for (var i = 0; i < 4; i++)
        i < (previous?.cascades.cascades.length ?? 0)
            ? previous!.cascades.cascades[i].matrix
            : Mat4.identity(),
    ];
    final camera = state.camera.position;
    final values = Float32List.fromList([
      valid && previous != null ? 1 : 0,
      state.cascades.cascades.length.toDouble(),
      .01,
      1,
      for (final matrix in matrices)
        ...() {
          final m = matrix.storage.toList();
          for (var r = 0; r < 4; r++) {
            m[12 + r] +=
                m[r] * camera.x + m[4 + r] * camera.y + m[8 + r] * camera.z;
          }
          return m;
        }(),
    ]);
    await scope.resources.writeBuffer(uniform, values);
    await graph.execute();
    _pending = state;
  }

  void presented() {
    _previous = _pending;
  }
}

const _resolve = r'''
struct ShadowHistory {state:vec4<f32>,previous:array<mat4x4<f32>,4>};
@group(2) @binding(8) var<uniform> sh:ShadowHistory;
@group(1) @binding(0) var rawShadow:texture_2d<f32>;
@group(1) @binding(1) var historyShadow:texture_2d<f32>;
@group(3) @binding(0) var outputShadow:texture_storage_2d<rgba32float,write>;
fn shadowHistorySample(uv:vec2<f32>,cascade:i32,size:vec2<i32>)->vec4<f32>{
 let p=uv*vec2<f32>(size)-.5;let base=vec2<i32>(floor(p));let f=fract(p);var value=vec4<f32>(0.);
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){
  let coord=clamp(base+vec2<i32>(x,y),vec2<i32>(0),size-1)+vec2<i32>(cascade*size.x,0);
  value+=textureLoad(historyShadow,coord,0)*select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);
 }}return value;
}
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let dimensions=textureDimensions(outputShadow);if(any(id.xy>=dimensions)){return;}
 let count=i32(sh.state.y);let size=vec2<i32>(i32(dimensions.x)/count,i32(dimensions.y));
 let cascade=i32(id.x)/size.x;let pixel=vec2<i32>(i32(id.x)%size.x,i32(id.y));let coord=vec2<i32>(id.xy);
 let current=textureLoad(rawShadow,coord,0);var output=current;
 if(sh.state.x>.5){
  var closest=current.x;var closestPixel=pixel;
  for(var y=-1;y<=1;y++){for(var x=-1;x<=1;x++){
   let p=clamp(pixel+vec2<i32>(x,y),vec2<i32>(0),size-1);
   let value=textureLoad(rawShadow,p+vec2<i32>(cascade*size.x,0),0).x;
   if(value<closest){closest=value;closestPixel=p;}
  }}
  let uv=(vec2<f32>(closestPixel)+.5)/vec2<f32>(size);let point=cf.inverseShadows[cascade]*vec4<f32>(uv.x*2.-1.,1.-uv.y*2.,-1.,1.);
  let origin=cloudEcef(point.xyz/point.w);let near=max(0.,cloudSphere(origin,-cf.sun.xyz,cf.camera.w+cloud.v[20].w).x);
  let front=cloudWorld(origin-cf.sun.xyz*(near+closest));let clip=sh.previous[cascade]*vec4<f32>(front,1.);
  let prevUv=vec2<f32>(clip.x/clip.w*.5+.5,.5-clip.y/clip.w*.5)+(vec2<f32>(pixel-closestPixel)/vec2<f32>(size));
  if(all(prevUv>=vec2<f32>(0.))&&all(prevUv<=vec2<f32>(1.))){
   let history=shadowHistorySample(prevUv,cascade,size);
   var first=current;var second=current*current;
   let offsets=array<vec2<i32>,8>(vec2<i32>(-1,-1),vec2<i32>(-1,1),vec2<i32>(1,-1),vec2<i32>(1,1),vec2<i32>(1,0),vec2<i32>(0,-1),vec2<i32>(0,1),vec2<i32>(-1,0));
   for(var i=0;i<8;i++){let p=clamp(pixel+offsets[i],vec2<i32>(0),size-1)+vec2<i32>(cascade*size.x,0);let v=textureLoad(rawShadow,p,0);first+=v;second+=v*v;}
   output=mix(cloudVariance(history,first,second,9.,sh.state.w),current,sh.state.z);
  }
 }
 textureStore(outputShadow,coord,max(output,vec4<f32>(0.)));
}
''';
const _copy = r'''
@group(1) @binding(0) var source:texture_2d<f32>;
@group(3) @binding(0) var destination:texture_storage_2d<rgba32float,write>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>){if(any(id.xy>=textureDimensions(destination))){return;}textureStore(destination,vec2<i32>(id.xy),textureLoad(source,vec2<i32>(id.xy),0));}
''';
