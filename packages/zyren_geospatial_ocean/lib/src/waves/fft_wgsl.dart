const oceanFftWgsl = '''
@group(0) @binding(0) var<uniform> config: vec4<u32>;
@group(0) @binding(1) var<storage, read> source: array<vec2<f32>>;
@group(0) @binding(2) var<storage, read_write> destination: array<vec2<f32>>;
fn address(frequency: u32, line: u32, channel: u32) -> u32 {
  let n = config.x;
  return channel*n*n + select(line*n + frequency, frequency*n + line, config.z == 1u);
}
@compute @workgroup_size(8,8,1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  let n = config.x;
  if (id.x >= n/2u || id.y >= n) { return; }
  let halfWidth = config.y;
  let k = id.x % halfWidth;
  let output = 2u*id.x - k;
  let phase = 6.283185307179586 * f32(k) / f32(2u*halfWidth);
  let a = source[address(id.x, id.y, id.z)];
  let b = source[address(id.x + n/2u, id.y, id.z)];
  let w = vec2(cos(phase), sin(phase));
  let product = vec2(b.x*w.x-b.y*w.y, b.x*w.y+b.y*w.x);
  let scale = select(1., 1./f32(n*n), config.w == 1u);
  destination[address(output, id.y, id.z)] = (a + product)*scale;
  destination[address(output + halfWidth, id.y, id.z)] = (a - product)*scale;
}
''';
