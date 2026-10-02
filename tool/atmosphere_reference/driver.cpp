void print(vec3 v){std::cout<<'['<<v.x<<','<<v.y<<','<<v.z<<']';}
int main(){
 AtmosphereParameters a;
 const int W=SCATTERING_TEXTURE_MU_S_SIZE*SCATTERING_TEXTURE_NU_SIZE,H=SCATTERING_TEXTURE_MU_SIZE,D=SCATTERING_TEXTURE_R_SIZE;
 Texture t(TRANSMITTANCE_TEXTURE_WIDTH,TRANSMITTANCE_TEXTURE_HEIGHT),r(W,H,D),mie(W,H,D),density(W,H,D),multiple(W,H,D),higher(W,H,D),deltaI(IRRADIANCE_TEXTURE_WIDTH,IRRADIANCE_TEXTURE_HEIGHT),irr(IRRADIANCE_TEXTURE_WIDTH,IRRADIANCE_TEXTURE_HEIGHT);
 for(int y=0;y<t.h;y++)for(int x=0;x<t.w;x++)t.set(x,y,0,ComputeTransmittanceToTopAtmosphereBoundaryTexture(a,vec2(x+.5,y+.5)));
 for(int y=0;y<deltaI.h;y++)for(int x=0;x<deltaI.w;x++)deltaI.set(x,y,0,ComputeDirectIrradianceTexture(a,&t,vec2(x+.5,y+.5)));
 for(int z=0;z<r.d;z++)for(int y=0;y<r.h;y++)for(int x=0;x<r.w;x++){
  vec3 ray,mi;ComputeSingleScatteringTexture(a,&t,vec3(x+.5,y+.5,z+.5),ray,mi);r.set(x,y,z,ray);mie.set(x,y,z,mi);
 }
 for(int order=2;order<=4;order++){
  for(int z=0;z<r.d;z++)for(int y=0;y<r.h;y++)for(int x=0;x<r.w;x++)density.set(x,y,z,ComputeScatteringDensityTexture(a,&t,&r,&mie,&multiple,&deltaI,vec3(x+.5,y+.5,z+.5),order));
  for(int y=0;y<irr.h;y++)for(int x=0;x<irr.w;x++){
   vec3 value=ComputeIndirectIrradianceTexture(a,&r,&mie,&multiple,vec2(x+.5,y+.5),order-1);
   deltaI.set(x,y,0,value);irr.set(x,y,0,vec3(irr.at(x,y))+value);
  }
  for(int z=0;z<r.d;z++)for(int y=0;y<r.h;y++)for(int x=0;x<r.w;x++){
   double nu;vec3 value=ComputeMultipleScatteringTexture(a,&t,&density,vec3(x+.5,y+.5,z+.5),nu);
   multiple.set(x,y,z,value);higher.set(x,y,z,vec3(higher.at(x,y,z))+value/RayleighPhaseFunction(nu));
  }
 }
 std::cout<<std::setprecision(17)<<"{\"tables\":{";
 int tableIndex=0;
 for(auto entry:std::vector<std::pair<const char*,Texture*>>{{"transmittance",&t},{"rayleigh",&r},{"mie",&mie},{"higher",&higher},{"irradiance",&irr}}){
  if(const char* prefix=std::getenv("ATMOSPHERE_DUMP")) {std::ofstream out(std::string(prefix)+"-"+entry.first+".bin",std::ios::binary);for(const auto& v:entry.second->data){out.write(reinterpret_cast<const char*>(&v),sizeof(v));}}
  if(tableIndex++)std::cout<<',';std::cout<<'"'<<entry.first<<"\":[";int n=0;auto tex=entry.second;
  for(int i=0;i<(int)tex->data.size();i++){
   // Deterministic stratification, retaining all boundaries and dark samples.
   const int x=i%tex->w,y=(i/tex->w)%tex->h;
   bool boundary=tex->d>1&&(y==0||y==tex->h-1||y==tex->h/2||y==tex->h/2-1)&&(x%SCATTERING_TEXTURE_MU_S_SIZE==0||x%SCATTERING_TEXTURE_MU_S_SIZE==SCATTERING_TEXTURE_MU_S_SIZE-1);
   if(i%max(1,int(tex->data.size()/256)|1)!=0 && i!=int(tex->data.size())-1&&!boundary)continue;
   if(n++)std::cout<<',';std::cout<<"{\"index\":"<<i<<",\"rgb\":";print(vec3(tex->data[i]));std::cout<<'}';
  }std::cout<<']';
 }std::cout<<"},\"optical\":[";int n=0;
 for(double altitude:{0.,.001,1.,10.,30.,59.,60.})for(double mu:{0.,.1,.5,1.}){
  if(n++)std::cout<<',';std::cout<<"{\"altitudeKm\":"<<altitude<<",\"mu\":"<<mu<<",\"rgb\":";print(ComputeTransmittanceToTopAtmosphereBoundary(a,a.bottom_radius+altitude,mu));std::cout<<'}';
 }std::cout<<"],\"radiance\":[";n=0;
 for(double altitude:{.001,.1,1.,10.,30.,59.9}){double rad=a.bottom_radius+altitude;double horizon=-sqrt(1-a.bottom_radius*a.bottom_radius/(rad*rad));
 for(double mu:{-1.,horizon-.01,horizon+.01,0.,.2,1.})for(double mus:{-.25,-.1,0.,.1,.5,1.})for(double phi:{0.,PI/2,PI}){
  double nu=clamp(mu*mus+sqrt((1-mu*mu)*(1-mus*mus))*cos(phi),-1.,1.);bool ground=RayIntersectsGround(a,rad,mu);
  vec3 value=(GetScattering(a,&r,rad,mu,mus,nu,ground)+GetScattering(a,&higher,rad,mu,mus,nu,ground))*RayleighPhaseFunction(nu)+GetScattering(a,&mie,rad,mu,mus,nu,ground)*MiePhaseFunction(a.mie_phase_function_g,nu);
  if(n++)std::cout<<',';std::cout<<"{\"coordinates\":["<<rad<<','<<mu<<','<<mus<<','<<nu<<"],\"rgb\":";print(value);std::cout<<'}';
 }}std::cout<<"],\"runtime\":[";n=0;
 Texture combined(W,H,D);for(int i=0;i<W*H*D;i++)combined.data[i]=r.data[i]+higher.data[i];
 vec3 luminance=vec3(114974.916437,71305.954816,65310.548555)/dot(vec3(98242.786222,69954.398112,66475.012354),vec3(.2126,.7152,.0722));
 for(auto c:std::vector<std::array<double,4>>{{6360.01,1,1,-1},{6360.01,.01,.02,-1},{6360.1,.5,-.25,-1},{6390,-.08,.5,-1},{6500,-.2,.5,-1},{6360.01,.5,.8,1},{6360.01,.1,.2,10},{6361,-.2,.5,10},{6500,-1,.5,200}}){
  vec3 camera(0,0,c[0]),ray(sqrt(1-c[1]*c[1]),0,c[1]),sun(sqrt(1-c[2]*c[2]),0,c[2]);vec3 tr;
  vec3 value=c[3]<0?GetSkyRadiance(a,&t,&combined,&mie,camera,ray,0,sun,tr):GetSkyRadianceToPoint(a,&t,&combined,&mie,camera,camera+ray*c[3],0,sun,tr);
  if(n++)std::cout<<',';std::cout<<"{\"input\":["<<c[0]<<','<<c[1]<<','<<c[2]<<','<<c[3]<<"],\"radiance\":";print(value*luminance);std::cout<<",\"transmittance\":";print(tr);std::cout<<'}';
 }std::cout<<"]}";
}
