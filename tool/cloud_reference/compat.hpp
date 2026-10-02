// Small float-vector host for the original GLSL, compiled with Clang.
#include <cmath>
#include <algorithm>
#include <iostream>
#include <iomanip>
using vec2 = float __attribute__((ext_vector_type(2)));
using vec3 = float __attribute__((ext_vector_type(3)));
using vec4 = float __attribute__((ext_vector_type(4)));
vec2 V2(float a){return {a,a};} vec2 V2(float a,float b){return {a,b};}
vec3 V3(float a){return {a,a,a};} vec3 V3(float a,float b,float c){return {a,b,c};}
vec3 V3(vec2 a,float b){return {a.x,a.y,b};}
vec4 V4(float a){return {a,a,a,a};} vec4 V4(float a,float b,float c,float d){return {a,b,c,d};}
vec4 V4(vec3 a,float b){return {a.x,a.y,a.z,b};}
float fract(float v){return v-floor(v);}
float mod(float a,float b){return a-floor(a/b)*b;}
float min(float a,float b){return std::min(a,b);} float max(float a,float b){return std::max(a,b);}
float clamp(float v,float a,float b){return min(max(v,a),b);} float saturate(float v){return clamp(v,0,1);}
float mix(float a,float b,float t){return a*(1-t)+b*t;}
float dot(vec2 a,vec2 b){return a.x*b.x+a.y*b.y;}
float dot(vec3 a,vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
float dot(vec4 a,vec4 b){return a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w;}
vec3 normalize(vec3 v){return v/std::sqrt(dot(v,v));}
float smoothstep(float a,float b,float x){float t=saturate((x-a)/(b-a));return t*t*(3-2*t);}
float remap(float x,float a,float b){return (x-a)/(b-a);}
float remap(float x,float a,float b,float c,float d){return mix(c,d,remap(x,a,b));}
vec2 mix(vec2 a,vec2 b,float t){return a*(1-t)+b*t;}
vec4 mix(vec4 a,vec4 b,float t){return a*(1-t)+b*t;}
vec3 floor(vec3 v){return {floor(v.x),floor(v.y),floor(v.z)};}
vec4 floor(vec4 v){return {floor(v.x),floor(v.y),floor(v.z),floor(v.w)};}
vec3 fract(vec3 v){return v-floor(v);} vec4 fract(vec4 v){return v-floor(v);}
vec3 mod(vec3 a,float b){return a-floor(a/b)*b;}
vec4 mod(vec4 a,vec4 b){return a-floor(a/b)*b;}
vec4 abs(vec4 v){return {abs(v.x),abs(v.y),abs(v.z),abs(v.w)};}
vec4 step(vec4 a,vec4 b){return {b.x<a.x?0.f:1.f,b.y<a.y?0.f:1.f,b.z<a.z?0.f:1.f,b.w<a.w?0.f:1.f};}
vec4 step(float a,vec4 b){return step(V4(a),b);}
