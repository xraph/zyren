void print(vec3 v){std::cout<<'['<<v.x<<','<<v.y<<','<<v.z<<']';}
double half(unsigned word) {
 const int exponent=(word>>10)&31, mantissa=word&1023;
 assert(exponent!=31);
 const double value=exponent==0?std::ldexp(double(mantissa),-24):std::ldexp(1.+mantissa/1024.,exponent-15);
 return word&0x8000?-value:value;
}
void load(Texture& texture,const char* name) {
 std::ifstream file(std::string(std::getenv("SOURCE_LUTS"))+"/"+name+".bin",std::ios::binary);
 assert(file.good());
 for(auto& texel:texture.data) {
  double values[4];
  for(int c=0;c<4;c++) {unsigned char bytes[2];file.read(reinterpret_cast<char*>(bytes),2);assert(file.good());values[c]=half(bytes[0]|unsigned(bytes[1])<<8);}
  texel=vec4(values[0],values[1],values[2],values[3]);
 }
 assert(file.peek()==EOF);
}
int main() {
 AtmosphereParameters a;
 Texture trans(256,64),scatter(256,128,32),mie(256,128,32);
 load(trans,"transmittance");load(scatter,"scattering");load(mie,"single_mie_scattering");
#ifdef HAS_HIGHER_ORDER_SCATTERING_TEXTURE
 Texture higher(256,128,32);load(higher,"higher_order_scattering");higher_order_scattering_texture=&higher;
#endif
 vec3 luminance=vec3(114974.916437,71305.954816,65310.548555)/dot(vec3(98242.786222,69954.398112,66475.012354),vec3(.2126,.7152,.0722));
 std::cout<<std::setprecision(17)<<"{\"runtime\":[";int n=0;
 for(auto c:std::vector<std::array<double,4>>{{6360.01,1,1,-1},{6360.01,.01,.02,-1},{6360.1,.5,-.25,-1},{6390,-.08,.5,-1},{6500,-.2,.5,-1},{6360.01,.5,.8,1},{6360.01,.1,.2,10},{6361,-.2,.5,10},{6500,-1,.5,200},{6360.01,.4,-.01,.001},{6360.01,.4,.01,.01},{6360.01,1,1,.1}}) {
#ifdef CLOUD_SHADOWS
 // Keep the double host away from exact-cosine assertion roundoff.
 c[1]=clamp(c[1],-.99,.99);
 for(double shadow:std::vector<double>{0,.1,1,5,20}) {
#else
 for(double shadow:std::vector<double>{0}) {
#endif
  vec3 camera(0,0,c[0]),ray(sqrt(1-c[1]*c[1]),0,c[1]),sun(sqrt(1-c[2]*c[2]),0,c[2]),tr;
  vec3 value=c[3]<0?GetSkyRadiance(a,&trans,&scatter,&mie,camera,ray,shadow,sun,tr):GetSkyRadianceToPoint(a,&trans,&scatter,&mie,camera,camera+ray*c[3],shadow,sun,tr);
  if(n++)std::cout<<',';
  std::cout<<"{\"input\":["<<c[0]<<','<<c[1]<<','<<c[2]<<','<<c[3]<<"],\"radiance\":";print(value*luminance);
#ifdef CLOUD_SHADOWS
  std::cout<<",\"shadow\":"<<shadow;
#endif
  std::cout<<",\"transmittance\":";print(tr);std::cout<<'}';
 }
 }
 std::cout<<"]}";
}
