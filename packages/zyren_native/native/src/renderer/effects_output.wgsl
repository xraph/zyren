
struct ScreenUniforms {
  inverseViewProjection: mat4x4<f32>,
  viewport: vec4<f32>, // width, height, history valid, exposure
  output: vec4<f32>, // tone map, sRGB output, spatial AA, encoded input
  depth: vec4<f32>, // reversed depth, reserved
};
@group(0) @binding(0) var sceneColor: texture_2d<f32>;
@group(0) @binding(1) var sceneDepth: texture_depth_2d;
@group(0) @binding(2) var historyColor: texture_2d<f32>;
@group(0) @binding(3) var<uniform> screen: ScreenUniforms;
struct ScreenVertex {
  @builtin(position) position: vec4<f32>,
  @location(0) uv: vec2<f32>,
};
@vertex fn vertex(@builtin(vertex_index) index: u32) -> ScreenVertex {
  let uv = vec2<f32>(f32((index << 1u) & 2u), f32(index & 2u));
  var v: ScreenVertex;
  v.position = vec4<f32>(uv * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
  v.uv = uv;
  return v;
}

fn toSrgb(x: vec3<f32>) -> vec3<f32> {
 return select(1.055 * pow(x, vec3<f32>(1.0/2.4)) - .055, x * 12.92, x <= vec3<f32>(.0031308));
}
fn fromSrgb(x: vec3<f32>) -> vec3<f32> {
 return select(pow((x + .055) / 1.055, vec3<f32>(2.4)), x / 12.92, x <= vec3<f32>(.04045));
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
fn outputPixel(p: vec2<i32>) -> vec4<f32> {
 let c = textureLoad(sceneColor, clamp(p, vec2<i32>(0), vec2<i32>(textureDimensions(sceneColor)) - vec2<i32>(1)), 0);
 if (screen.output.w == 1.) { return c; }
 let alpha = clamp(c.a, 0., 1.);
 var rgb = max(c.rgb / max(alpha, 1e-6) * screen.viewport.w, vec3<f32>(0.));
 if (screen.output.x == 1.) { rgb = rgb / (vec3<f32>(1.) + rgb); }
 if (screen.output.x == 3.) { rgb = clamp((rgb * (2.51 * rgb + .03)) / (rgb * (2.43 * rgb + .59) + .14), vec3<f32>(0.), vec3<f32>(1.)); }
 if (screen.output.x == 4.) { rgb = cineon(rgb); }
 if (screen.output.x == 2.) { rgb = acesFilmic(rgb); }
 if (screen.output.x == 5.) { rgb = agx(rgb); }
 if (screen.output.x == 6.) { rgb = neutral(rgb); }
 let encoded = toSrgb(clamp(rgb, vec3<f32>(0.), vec3<f32>(1.))) * alpha;
 return vec4<f32>(encoded, alpha);
}

// FXAA adapted from Three.js r184 FXAAShader (MIT). See THIRD_PARTY_NOTICES.md.
// Filter tone-mapped, encoded, premultiplied pixels. Alpha edges also matter on
// a transparent host, including black silhouettes with no luminance contrast.
fn sampleOutput(p: vec2<f32>) -> vec4<f32> {
 let base = vec2<i32>(floor(p - .5)); let f = fract(p - .5);
 return mix(mix(outputPixel(base), outputPixel(base + vec2<i32>(1,0)), f.x),
            mix(outputPixel(base + vec2<i32>(0,1)), outputPixel(base + vec2<i32>(1)), f.x), f.y);
}
fn luma(p: vec2<f32>, alphaEdge: bool) -> f32 {
 let c = sampleOutput(p);
 return select(dot(c.rgb, vec3<f32>(.3,.59,.11)), c.a, alphaEdge);
}
fn fxaa(p: vec2<f32>) -> vec4<f32> {
 let center = outputPixel(vec2<i32>(p));
 let cn = outputPixel(vec2<i32>(p) + vec2<i32>(0,1));
 let ce = outputPixel(vec2<i32>(p) + vec2<i32>(1,0));
 let cs = outputPixel(vec2<i32>(p) + vec2<i32>(0,-1));
 let cw = outputPixel(vec2<i32>(p) + vec2<i32>(-1,0));
 let lum = vec3<f32>(.3,.59,.11);
 let card = vec4<f32>(dot(cn.rgb,lum),dot(ce.rgb,lum),dot(cs.rgb,lum),dot(cw.rgb,lum));
 let alphas = vec4<f32>(cn.a,ce.a,cs.a,cw.a);
 let cmin = min(dot(center.rgb,lum), min(min(card.x,card.y),min(card.z,card.w)));
 let cmax = max(dot(center.rgb,lum), max(max(card.x,card.y),max(card.z,card.w)));
 let amin = min(center.a, min(min(alphas.x,alphas.y),min(alphas.z,alphas.w)));
 let amax = max(center.a, max(max(alphas.x,alphas.y),max(alphas.z,alphas.w)));
 let alphaEdge = amax - amin > cmax - cmin;
 let m = select(dot(center.rgb,lum),center.a,alphaEdge);
 let n = select(card.x,cn.a,alphaEdge); let e = select(card.y,ce.a,alphaEdge);
 let s = select(card.z,cs.a,alphaEdge); let w = select(card.w,cw.a,alphaEdge);
 let highest = select(cmax,amax,alphaEdge); let lowest = select(cmin,amin,alphaEdge);
 let contrast = highest - lowest;
 if (contrast < max(.0312, .063 * highest)) { return center; }
 let ne = luma(p + vec2<f32>(1,1),alphaEdge); let nw = luma(p + vec2<f32>(-1,1),alphaEdge);
 let se = luma(p + vec2<f32>(1,-1),alphaEdge); let sw = luma(p + vec2<f32>(-1,-1),alphaEdge);
 let f = clamp(abs((2. * (n+e+s+w) + ne+nw+se+sw)/12. - m)/contrast, 0., 1.);
 let smoothed = f*f*(3.-2.*f); let pixelBlend = smoothed*smoothed;
 let horizontal = 2.*abs(n+s-2.*m) + abs(ne+se-2.*e) + abs(nw+sw-2.*w);
 let vertical = 2.*abs(e+w-2.*m) + abs(ne+nw-2.*n) + abs(se+sw-2.*s);
 let isHorizontal = horizontal >= vertical;
 let positive = select(e,n,isHorizontal); let negative = select(w,s,isHorizontal);
 let pg = abs(positive-m); let ng = abs(negative-m);
 let step = select(1.,-1.,pg < ng);
 let opposite = select(positive,negative,pg < ng);
 let gradient = max(pg,ng);
 let across = select(vec2<f32>(step,0.),vec2<f32>(0.,step),isHorizontal);
 let along = select(vec2<f32>(0.,1.),vec2<f32>(1.,0.),isHorizontal);
 let start = p + across * .5;
 let edgeLuminance = (m+opposite)*.5; let threshold = gradient*.25;
 let steps = array<f32,6>(1.,1.5,2.,2.,2.,4.);
 var puv = start + along; var nuv = start - along;
 var pd = luma(puv,alphaEdge)-edgeLuminance; var nd = luma(nuv,alphaEdge)-edgeLuminance;
 var pend = abs(pd)>=threshold; var nend = abs(nd)>=threshold;
 for(var i=1u; i<6u; i++) {
   if (!pend) { puv += along*steps[i]; pd=luma(puv,alphaEdge)-edgeLuminance; pend=abs(pd)>=threshold; }
   if (!nend) { nuv -= along*steps[i]; nd=luma(nuv,alphaEdge)-edgeLuminance; nend=abs(nd)>=threshold; }
 }
 if (!pend) { puv += along*8.; } if (!nend) { nuv -= along*8.; }
 let pDistance = dot(puv-p,along); let nDistance = dot(p-nuv,along);
 let shortest = min(pDistance,nDistance);
 let deltaSign = select(nd>=0.,pd>=0.,pDistance<=nDistance);
 let edgeBlend = select(.5-shortest/(pDistance+nDistance),0.,deltaSign==(m-edgeLuminance>=0.));
 return sampleOutput(p + across * max(pixelBlend,edgeBlend));
}
@fragment fn fragment(v: ScreenVertex) -> @location(0) vec4<f32> {
 var c = outputPixel(vec2<i32>(v.position.xy));
 if (screen.output.z == 1.) { c = fxaa(v.position.xy); }
 return vec4<f32>(select(c.rgb, fromSrgb(c.rgb), screen.output.y == 1.), c.a);
}

@fragment fn display(v: ScreenVertex) -> @location(0) vec4<f32> {
 return outputPixel(vec2<i32>(v.position.xy));
}
