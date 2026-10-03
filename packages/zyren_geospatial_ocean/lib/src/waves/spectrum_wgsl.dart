const oceanSpectrumWgsl = '''
// config: size, wave-number step, choppiness, seconds since a CPU phase anchor.
@group(0) @binding(0) var<uniform> config: vec4<f32>;
// h0 real, h0 imaginary, positive omega, negative-time phase at the anchor.
@group(0) @binding(1) var<storage, read> seeds: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read_write> fields: array<vec2<f32>>;
fn multiply(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
  return vec2(a.x*b.x-a.y*b.y, a.x*b.y+a.y*b.x);
}
fn pack(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
  return a + vec2(-b.y, b.x);
}
@compute @workgroup_size(8,8,1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  let n = u32(config.x);
  if (id.x >= n || id.y >= n) { return; }
  let count = n*n;
  let index = id.y*n+id.x;
  let mirror = ((n-id.y)%n)*n+(n-id.x)%n;
  let a = seeds[index];
  let b = seeds[mirror];
  let phase = a.w - a.z*config.w;
  let w = vec2(cos(phase), sin(phase));
  let p = multiply(a.xy, w);
  let q = multiply(vec2(b.x, -b.y), vec2(w.x, -w.y));
  let h = p+q;
  let delta = p-q;
  let velocity = a.z*vec2(delta.y, -delta.x);
  let nx = select(i32(id.x), i32(id.x)-i32(n), id.x >= n/2u);
  let nz = select(i32(id.y), i32(id.y)-i32(n), id.y >= n/2u);
  let k = vec2(f32(nx), f32(nz))*config.y;
  let length = max(length(k), 1e-20);
  let ax = config.z*k.x/length;
  let az = config.z*k.y/length;
  let dx = ax*vec2(h.y, -h.x);
  let dz = az*vec2(h.y, -h.x);
  let sx = k.x*vec2(-h.y, h.x);
  let sz = k.y*vec2(-h.y, h.x);
  let vx = ax*vec2(velocity.y, -velocity.x);
  let vz = az*vec2(velocity.y, -velocity.x);
  fields[index] = pack(h, dx);
  fields[count+index] = pack(dz, sx);
  fields[2u*count+index] = pack(sz, vx);
  fields[3u*count+index] = pack(velocity, vz);
  fields[4u*count+index] = pack(ax*k.x*h, ax*k.y*h);
  fields[5u*count+index] = az*k.y*h;
}
''';

const oceanPackWgsl = '''
@group(0) @binding(0) var<uniform> config: vec4<f32>;
@group(0) @binding(1) var<storage, read> fields: array<vec2<f32>>;
@group(0) @binding(2) var displacement: texture_storage_2d<rgba32float, write>;
@group(0) @binding(3) var derivatives: texture_storage_2d<rgba32float, write>;
@group(0) @binding(4) var velocity: texture_storage_2d<rgba32float, write>;
@compute @workgroup_size(8,8,1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  let n = u32(config.x);
  if (id.x >= n || id.y >= n) { return; }
  let count = n*n;
  let i = id.y*n+id.x;
  let a = fields[i];
  let b = fields[count+i];
  let c = fields[2u*count+i];
  let d = fields[3u*count+i];
  let e = fields[4u*count+i];
  let f = fields[5u*count+i];
  let jacobian = (1.+e.x)*(1.+f.x)-e.y*e.y;
  textureStore(displacement, vec2<i32>(id.xy), vec4(a.y, a.x, b.x, jacobian));
  textureStore(derivatives, vec2<i32>(id.xy), vec4(b.y, c.x, e.x, f.x));
  textureStore(velocity, vec2<i32>(id.xy), vec4(c.y, d.x, d.y, e.y));
}
''';
