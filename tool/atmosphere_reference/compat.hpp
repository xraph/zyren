// Minimal CPU host for the pinned upstream GLSL equations, using double precision.
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <vector>
using std::sqrt; using std::exp; using std::pow; using std::floor;
using std::sin; using std::cos; using std::min; using std::max;
struct vec4;
struct vec2 {
 double x=0,y=0; vec2(){} vec2(double a):x(a),y(a){} vec2(double a,double b):x(a),y(b){}
 vec2 operator*(double a)const{return {x*a,y*a};}
 vec2 operator/(const vec2& b)const{return {x/b.x,y/b.y};}
};
struct vec3 {
 double x=0,y=0,z=0;
 vec3(){} vec3(double a):x(a),y(a),z(a){} vec3(double a,double b,double c):x(a),y(b),z(c){} vec3(const vec4&);
 vec3 operator+(vec3 b)const{return {x+b.x,y+b.y,z+b.z};}
 vec3 operator-(vec3 b)const{return {x-b.x,y-b.y,z-b.z};}
 vec3 operator*(vec3 b)const{return {x*b.x,y*b.y,z*b.z};}
 vec3 operator/(vec3 b)const{return {x/b.x,y/b.y,z/b.z};}
 vec3 operator-()const{return {-x,-y,-z};}
 vec3& operator+=(vec3 b){*this=*this+b;return *this;}
};
vec3 operator*(double a,vec3 b){return b*a;}
struct vec4 {
 double x=0,y=0,z=0,w=0;
 vec4(){} vec4(double a):x(a),y(a),z(a),w(a){} vec4(double a,double b,double c,double d):x(a),y(b),z(c),w(d){}
 vec4(vec3 v,double a):x(v.x),y(v.y),z(v.z),w(a){}
 vec4 operator/(vec4 b)const{return {x/b.x,y/b.y,z/b.z,w/b.w};}
 vec4 operator*(double a)const{return {x*a,y*a,z*a,w*a};}
 vec4 operator+(vec4 b)const{return {x+b.x,y+b.y,z+b.z,w+b.w};}
};
vec3::vec3(const vec4& v):x(v.x),y(v.y),z(v.z){}
double clamp(double x,double a,double b){return min(max(x,a),b);}
vec3 min(vec3 a,vec3 b){return {min(a.x,b.x),min(a.y,b.y),min(a.z,b.z)};}
vec3 exp(vec3 a){return {exp(a.x),exp(a.y),exp(a.z)};}
double dot(vec3 a,vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
vec3 normalize(vec3 a){return a/sqrt(dot(a,a));}
double smoothstep(double a,double b,double x){double t=clamp((x-a)/(b-a),0.,1.);return t*t*(3-2*t);}
double mod(double x,double y){return x-floor(x/y)*y;}
struct Texture {
 int w,h,d; std::vector<vec4> data;
 Texture(int w,int h,int d=1):w(w),h(h),d(d),data(w*h*d){}
 vec4 at(int x,int y,int z=0)const {return data[(std::clamp(z,0,d-1)*h+std::clamp(y,0,h-1))*w+std::clamp(x,0,w-1)];}
 void set(int x,int y,int z,vec3 v){data[(z*h+y)*w+x]=vec4(v,1);}
};
vec4 texture(const Texture* t,vec2 uv) {
 double x=uv.x*t->w-.5,y=uv.y*t->h-.5;int i=floor(x),j=floor(y);x-=i;y-=j;
 return (t->at(i,j)*(1-x)+t->at(i+1,j)*x)*(1-y)+(t->at(i,j+1)*(1-x)+t->at(i+1,j+1)*x)*y;
}
vec4 texture(const Texture* t,vec3 uv) {
 double z=uv.z*t->d-.5;int k=floor(z);z-=k;
 auto slice=[&](int k){double x=uv.x*t->w-.5,y=uv.y*t->h-.5;int i=floor(x),j=floor(y);x-=i;y-=j;
 return (t->at(i,j,k)*(1-x)+t->at(i+1,j,k)*x)*(1-y)+(t->at(i,j+1,k)*(1-x)+t->at(i+1,j+1,k)*x)*y;};
 return slice(k)*(1-z)+slice(k+1)*z;
}
#define Position vec3
#define Direction vec3
#define GROUND
double length(vec3 v){return sqrt(dot(v,v));}
#define Number double
#define Length double
#define Area double
#define Angle double
#define SolidAngle double
#define InverseSolidAngle double
#define DimensionlessSpectrum vec3
#define IrradianceSpectrum vec3
#define RadianceSpectrum vec3
#define RadianceDensitySpectrum vec3
#define AbstractSpectrum vec3
using TransmittanceTexture = const Texture*;
using IrradianceTexture = const Texture*;
using ReducedScatteringTexture = const Texture*;
using ScatteringTexture = const Texture*;
using AbstractScatteringTexture = const Texture*;
using ScatteringDensityTexture = const Texture*;
const double PI=3.141592653589793,pi=PI,rad=1,m=1,m2=1,sr=1;
const double watt_per_square_meter_per_sr_per_nm=1,watt_per_cubic_meter_per_sr_per_nm=1,watt_per_square_meter_per_nm=1;
struct DensityProfileLayer {double width,exp_term,exp_scale,linear_term,constant_term;};
struct DensityProfile {DensityProfileLayer layers[2];};
struct AtmosphereParameters {
 double bottom_radius=6360,top_radius=6420,sun_angular_radius=.004675,mu_s_min=-.5,mie_phase_function_g=.8;
 vec3 solar_irradiance={1.474,1.8504,1.91198},rayleigh_scattering={.005802,.013558,.0331},mie_scattering={.003996},mie_extinction={.00444},absorption_extinction={.00065,.001881,.000085},ground_albedo={.1};
 DensityProfile rayleigh_density={{{0,0,0,0,0},{0,1,-.125,0,0}}};
 DensityProfile mie_density={{{0,0,0,0,0},{0,1,-.833333,0,0}}};
 DensityProfile absorption_density={{{25,0,0,1./15,-2./3},{0,0,0,-1./15,8./3}}};
};
