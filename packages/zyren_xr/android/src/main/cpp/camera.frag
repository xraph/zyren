#version 450
layout(set=0,binding=0) uniform sampler2D cameraImage;
layout(set=0,binding=1) uniform sampler2D sceneImage;
layout(push_constant) uniform Calibration { vec4 row0; vec4 row1; } calibration;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 color;
vec3 linearize(vec3 s) { return mix(s/12.92,pow((s+.055)/1.055,vec3(2.4)),greaterThan(s,vec3(.04045))); }
vec3 encodeSrgb(vec3 c) { return mix(c*12.92,1.055*pow(max(c,vec3(0)),vec3(1.0/2.4))-.055,greaterThan(c,vec3(.0031308))); }
void main() {
 vec2 cameraUv=vec2(dot(calibration.row0.xyz,vec3(uv,1)),dot(calibration.row1.xyz,vec3(uv,1)));
 vec3 camera=linearize(texture(cameraImage,cameraUv).rgb);
 vec4 scene=texture(sceneImage,uv);
 // Native surface pixels premultiply encoded sRGB. Undo that storage encoding
 // before multiplying straight linear color by alpha for camera composition.
 vec3 straight=scene.a>0 ? linearize(clamp(encodeSrgb(scene.rgb)/scene.a,vec3(0),vec3(1))) : vec3(0);
 color=vec4(straight*scene.a+camera*(1-scene.a),1);
}
