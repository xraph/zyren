// Bruneton precomputation equations. See licenses/bruneton.txt.
const transmittanceWgsl = r'''
let c=transmittanceCoord((vec2<f32>(id.xy)+.5)/T_SIZE);let r=c.x;let mu=c.y;let dx=topDistance(r,mu)/500.;var depth=vec3<f32>(0.);
for(var i=0;i<=500;i++) {let d=f32(i)*dx;let h=max(0.,safeSqrt(d*d+2.*r*mu*d+r*r)-BOTTOM);let weight=select(1.,.5,i==0||i==500);
 depth+=(RAYLEIGH*rayDensity(h)+MIE_EXT*mieDensity(h)+ABSORPTION*absorptionDensity(h))*weight*dx;}
textureStore(output,vec2<i32>(id.xy),vec4<f32>(exp(-depth),1.));
''';
const directIrradianceWgsl = r'''
let c=irradianceCoord((vec2<f32>(id.xy)+.5)/I_SIZE);let mus=c.y;var average=0.;
if(mus>SUN_RADIUS){average=mus;}else if(mus>=-SUN_RADIUS){average=(mus+SUN_RADIUS)*(mus+SUN_RADIUS)/(4.*SUN_RADIUS);}
textureStore(output,vec2<i32>(id.xy),vec4<f32>(SOLAR*transTop(transmittance,c.x,mus)*average,1.));
''';
const singleScatteringWgsl = r'''
let c=scatteringCoord(vec3<f32>(id)+.5);let dx=boundary(c.r,c.mu,c.ground)/50.;var ray=vec3<f32>(0.);var mi=vec3<f32>(0.);
for(var i=0;i<=50;i++) {let d=f32(i)*dx;let rd=radius(safeSqrt(d*d+2.*c.r*c.mu*d+c.r*c.r));let mus=cosine((c.r*c.mus+d*c.nu)/rd);
 let tr=transPath(transmittance,c.r,c.mu,d,c.ground)*transSun(transmittance,rd,mus);let w=select(1.,.5,i==0||i==50);
 ray+=tr*rayDensity(rd-BOTTOM)*w;mi+=tr*mieDensity(rd-BOTTOM)*w;
}
textureStore(rayleigh,vec3<i32>(id),vec4<f32>(ray*dx*SOLAR*RAYLEIGH,1.));
textureStore(mie,vec3<i32>(id),vec4<f32>(mi*dx*SOLAR*MIE,1.));
''';
const incidentWgsl = r'''
fn incident(r:f32,mu:f32,mus:f32,nu:f32,ground:bool)->vec3<f32> {
 if(ORDER==2){return scattering(rayleigh,r,mu,mus,nu,ground)*rayPhase(nu)+scattering(mie,r,mu,mus,nu,ground)*miePhase(nu);}
 return scattering(multiple,r,mu,mus,nu,ground);
}
''';
const scatteringDensityWgsl = r'''
let c=scatteringCoord(vec3<f32>(id)+.5);let omega=vec3<f32>(safeSqrt(1.-c.mu*c.mu),0.,c.mu);var sx=0.;
if(omega.x!=0.){sx=(c.nu-c.mu*c.mus)/omega.x;}let sun=vec3<f32>(sx,safeSqrt(1.-sx*sx-c.mus*c.mus),c.mus);
let step=PI/16.;var sum=vec3<f32>(0.);let ray=RAYLEIGH*rayDensity(c.r-BOTTOM);let mi=MIE*mieDensity(c.r-BOTTOM);
for(var l=0;l<16;l++) {let theta=(f32(l)+.5)*step;let ct=cos(theta);let st=sin(theta);let ground=hitsGround(c.r,ct);var distance=0.;var groundTransmission=vec3<f32>(0.);
 if(ground){distance=groundDistance(c.r,ct);groundTransmission=transPath(transmittance,c.r,ct,distance,true);}
 for(var m=0;m<32;m++){let phi=(f32(m)+.5)*step;let wi=vec3<f32>(cos(phi)*st,sin(phi)*st,ct);let solidAngle=step*step*st;
 let nu1=cosine(dot(sun,wi));var incoming=incident(c.r,ct,c.mus,nu1,ground);
 let normal=normalize(vec3<f32>(0.,0.,c.r)+wi*distance);let groundIrradiance=irradiance(deltaIrradiance,BOTTOM,cosine(dot(normal,sun)));
 incoming+=groundTransmission*ALBEDO/PI*groundIrradiance;let nu2=cosine(dot(omega,wi));sum+=incoming*(ray*rayPhase(nu2)+mi*miePhase(nu2))*solidAngle;
 }}
textureStore(output,vec3<i32>(id),vec4<f32>(max(sum,vec3<f32>(0.)),1.));
''';
const indirectIrradianceWgsl = r'''
let c=irradianceCoord((vec2<f32>(id.xy)+.5)/I_SIZE);let sun=vec3<f32>(safeSqrt(1.-c.y*c.y),0.,c.y);let step=PI/32.;var sum=vec3<f32>(0.);
for(var j=0;j<16;j++){let theta=(f32(j)+.5)*step;let st=sin(theta);let ct=cos(theta);
 for(var i=0;i<64;i++){let phi=(f32(i)+.5)*step;let omega=vec3<f32>(cos(phi)*st,sin(phi)*st,ct);
 sum+=incident(c.x,ct,c.y,cosine(dot(omega,sun)),false)*ct*step*step*st;}}
textureStore(deltaIrradiance,vec2<i32>(id.xy),vec4<f32>(sum,1.));
textureStore(output,vec2<i32>(id.xy),vec4<f32>(sum+textureLoad(previous,vec2<i32>(id.xy),0).rgb,1.));
''';
const multipleScatteringWgsl = r'''
let c=scatteringCoord(vec3<f32>(id)+.5);let dx=boundary(c.r,c.mu,c.ground)/50.;var sum=vec3<f32>(0.);
for(var i=0;i<=50;i++){let d=f32(i)*dx;let r=radius(safeSqrt(d*d+2.*c.r*c.mu*d+c.r*c.r));let mu=cosine((c.r*c.mu+d)/r);let mus=cosine((c.r*c.mus+d*c.nu)/r);
 let value=scattering(density,r,mu,mus,c.nu,c.ground)*transPath(transmittance,c.r,c.mu,d,c.ground)*dx;let weight=select(1.,.5,i==0||i==50);sum+=value*weight;}
textureStore(multiple,vec3<i32>(id),vec4<f32>(sum,1.));
textureStore(output,vec3<i32>(id),vec4<f32>(textureLoad(previous,vec3<i32>(id),0).rgb+sum/rayPhase(c.nu),1.));
''';
