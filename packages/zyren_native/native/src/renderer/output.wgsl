@group(0) @binding(0) var source: texture_2d<f32>;
struct Parameters { exposure: vec4<f32> };
@group(0) @binding(1) var<uniform> parameters: Parameters;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}
fn encode_srgb(rgb: vec3<f32>) -> vec3<f32> {
  return select(1.055 * pow(max(rgb, vec3(0.)), vec3(1. / 2.4)) - .055,
                12.92 * rgb, rgb <= vec3(.0031308));
}
fn decode_srgb(rgb: vec3<f32>) -> vec3<f32> {
  return select(pow(max((rgb + .055) / 1.055, vec3(0.)), vec3(2.4)),
                rgb / 12.92, rgb <= vec3(.04045));
}
// Three.js r184 tone mapping (MIT), see THIRD_PARTY_NOTICES.md.
fn cineon(c:vec3<f32>)->vec3<f32> {
 let x=max(c-.004,vec3<f32>(0.));
 return pow((x*(6.2*x+.5))/(x*(6.2*x+1.7)+.06),vec3<f32>(2.2));
}
fn acesFilmic(c:vec3<f32>)->vec3<f32> {
 let input=mat3x3<f32>(vec3<f32>(.59719,.076,.0284),vec3<f32>(.35458,.90834,.13383),vec3<f32>(.04823,.01566,.83777));
 let output=mat3x3<f32>(vec3<f32>(1.60475,-.10208,-.00327),vec3<f32>(-.53108,1.10813,-.07276),vec3<f32>(-.07367,-.00605,1.07602));
 let v=input*(c/.6);
 let fit=(v*(v+.0245786)-.000090537)/(v*(.983729*v+.432951)+.238081);
 return clamp(output*fit,vec3<f32>(0.),vec3<f32>(1.));
}
fn agx(c:vec3<f32>)->vec3<f32> {
 let to2020=mat3x3<f32>(vec3<f32>(.6274,.0691,.0164),vec3<f32>(.3293,.9195,.088),vec3<f32>(.0433,.0113,.8956));
 let toSrgb=mat3x3<f32>(vec3<f32>(1.6605,-.1246,-.0182),vec3<f32>(-.5876,1.1329,-.1006),vec3<f32>(-.0728,-.0083,1.1187));
 let inset=mat3x3<f32>(vec3<f32>(.856627153315983,.137318972929847,.11189821299995),vec3<f32>(.0951212405381588,.761241990602591,.0767994186031903),vec3<f32>(.0482516061458583,.101439036467562,.811302368396859));
 let outset=mat3x3<f32>(vec3<f32>(1.1271005818144368,-.1413297634984383,-.14132976349843826),vec3<f32>(-.11060664309660323,1.157823702216272,-.11060664309660294),vec3<f32>(-.016493938717834573,-.016493938717834257,1.2519364065950405));
 let x=clamp((log2(max(inset*(to2020*c),vec3<f32>(1e-10)))+12.47393)/(4.026069+12.47393),vec3<f32>(0.),vec3<f32>(1.));
 let x2=x*x; let x4=x2*x2;
 let contrast=15.5*x4*x2-40.14*x4*x+31.96*x4-6.868*x2*x+.4298*x2+.1191*x-.00232;
 return clamp(toSrgb*pow(max(outset*contrast,vec3<f32>(0.)),vec3<f32>(2.2)),vec3<f32>(0.),vec3<f32>(1.));
}
fn neutral(c:vec3<f32>)->vec3<f32> {
 let x=min(c.x,min(c.y,c.z));
 var color=c-select(.04,x-6.25*x*x,x<.08);
 let peak=max(color.x,max(color.y,color.z));
 if(peak<.76){return color;}
 let newPeak=1.-.24*.24/(peak+.24-.76);
 color*=newPeak/peak;
 return mix(color,vec3<f32>(newPeak),1.-1./(.15*(peak-newPeak)+1.));
}

// ACES fit and viewing exposure follow Three.js. See THIRD_PARTY_NOTICES.md.
fn tone_map(rgb: vec3<f32>) -> vec3<f32> {
  var c = clamp(rgb, vec3(0.), vec3(65504.)) * parameters.exposure.x;
  if (__CURVE__ == 1u) { return c / (vec3(1.) + c); }
  if (__CURVE__ == 2u) {
    let to_ap1 = mat3x3<f32>(vec3(.59719,.07600,.02840),
      vec3(.35458,.90834,.13383), vec3(.04823,.01566,.83777));
    let to_srgb = mat3x3<f32>(vec3(1.60475,-.10208,-.00327),
      vec3(-.53108,1.10813,-.07276), vec3(-.07367,-.00605,1.07602));
    c = to_ap1 * (c / .6);
    c = (c * (c + .0245786) - .000090537) / (c * (.983729 * c + .4329510) + .238081);
    c = to_srgb * c;
  }
  if (__CURVE__ == 3u) { c = (c * (2.51 * c + .03)) / (c * (2.43 * c + .59) + .14); }
  if (__CURVE__ == 4u) { c = cineon(c); }
  if (__CURVE__ == 5u) { c = agx(c); }
  if (__CURVE__ == 6u) { c = neutral(c); }
  return clamp(c, vec3(0.), vec3(1.));
}
@fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  var color = textureLoad(source, vec2<i32>(pixel.xy), 0);
  if (__UNASSOCIATE__) {
    color = vec4(select(vec3(0.), color.rgb / max(color.a, 1e-8), color.a > 0.), color.a);
  }
  if (__HDR__) { color = vec4(tone_map(color.rgb), color.a); }
  if (__PREMULTIPLY__) {
    if (__SRGB__) {
      color = vec4(decode_srgb(encode_srgb(color.rgb) * color.a), color.a);
    } else {
      color = vec4(color.rgb * color.a, color.a);
    }
  }
  return color;
}
