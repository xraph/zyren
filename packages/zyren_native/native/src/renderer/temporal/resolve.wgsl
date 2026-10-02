@group(0) @binding(0) var current: texture_2d<f32>;
@group(0) @binding(1) var motion: texture_2d<f32>;
@group(0) @binding(2) var depth: texture_depth_2d;
@group(0) @binding(3) var history: texture_2d<f32>;
@group(0) @binding(4) var history_depth: texture_2d<f32>;
struct Params { settings: vec4<f32> };
@group(0) @binding(5) var<uniform> params: Params;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let corners=array<vec2<f32>,3>(vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));
    return vec4(corners[i],0.,1.);
}
fn associated(color: vec4<f32>) -> vec4<f32> { let a=clamp(color.a,0.,1.); return vec4(clamp(color.rgb,vec3(0.),vec3(65504.))*a,a); }
struct Result { @location(0) color: vec4<f32>, @location(1) history: vec4<f32>, @location(2) depth: f32 };
@fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> Result {
    let size=vec2<i32>(textureDimensions(current)); let p=vec2<i32>(pixel.xy);
    let c=associated(textureLoad(current,p,0)); let z=textureLoad(depth,p,0);
    let reversed=params.settings.w>.5;
    var lo=c; var hi=c;
    var selected=textureLoad(motion,p,0); var nearest=z;
    let reactive=selected.w<0.;
    // Dilate motion from the nearest visible surface across subpixel edges.
    for(var y=-1;y<=1;y++) { for(var x=-1;x<=1;x++) {
        let q=clamp(p+vec2(x,y),vec2(0),size-vec2(1));
        let neighbor=associated(textureLoad(current,q,0));
        lo=min(lo,neighbor);hi=max(hi,neighbor);
        let candidate=textureLoad(depth,q,0);
        if(select((candidate < nearest), (candidate > nearest), reversed)) { nearest=candidate;selected=textureLoad(motion,q,0); }
    } }
    let uv=pixel.xy/vec2<f32>(size);
    // Motion stores a UV displacement, predicted previous depth and validity.
    var previous=uv+selected.xy;
    var expected=selected.z;
    var valid=selected.w>.5;
    if(select((nearest >= 1.), (nearest <= 0.), reversed)) { previous=uv; expected=select(1.,0.,reversed); valid=true; }
    valid=valid && !reactive;
    valid=valid && params.settings.z>.5 && all(previous>=vec2(0.)) && all(previous<vec2(1.));
    let coordinate=previous*vec2<f32>(size)-vec2(.5);
    let base=vec2<i32>(floor(coordinate));let fraction=fract(coordinate);
    var history_color=vec4(0.);var depth_match=false;
    // Validate the footprint against its visible surface. Keep all color taps
    // so fractional coverage at a silhouette is not renormalized to opaque.
    for(var y=0;y<2;y++) { for(var x=0;x<2;x++) {
        let q=clamp(base+vec2(x,y),vec2(0),size-vec2(1));
        let z_old=textureLoad(history_depth,q,0).r;
        let tolerance=max(1e-6,params.settings.y*max(select(1.-expected,expected,reversed),1e-4));
        let w=select(1.-fraction.x,fraction.x,x==1)*select(1.-fraction.y,fraction.y,y==1);
        depth_match=depth_match || (w>.01 && abs(z_old-expected)<=tolerance);
        history_color+=textureLoad(history,q,0)*w;
    } }
    var result=c;
    if(valid && depth_match) {
        let clipped=clamp(history_color,lo,hi);
        result=mix(c,clipped,params.settings.x);
    }
    let straight=vec4(select(vec3(0.),result.rgb/max(result.a,1e-8),result.a>0.),result.a);
    return Result(straight,result,nearest);
}
