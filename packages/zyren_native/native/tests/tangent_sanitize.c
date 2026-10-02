#include <stdint.h>
#include <stdio.h>
#include <math.h>
int fg_mikk_bounded(const float*, const float*, const float*, const uint32_t*, uint32_t, float*, size_t, uint64_t);
static uint32_t state=17;
static float random_float(void){state=state*1664525u+1013904223u;return (float)(state%2001)/1000-1;}
int main(void){
 float p[192],n[192],uv[128],out[768];uint32_t indices[192];
 for(int run=0;run<1000;run++){
  for(int v=0;v<64;v++){for(int c=0;c<3;c++){p[v*3+c]=run%8 ? random_float() : 0;n[v*3+c]=c==2?1:0;}for(int c=0;c<2;c++)uv[v*2+c]=run%5 ? random_float() : 0;}
  for(int i=0;i<192;i++){state=state*1664525u+1013904223u;indices[i]=state%64;}
  int result=fg_mikk_bounded(p,n,uv,indices,192,out,8*1024*1024,1000000);
  if(result!=0 && result!=2){fprintf(stderr,"status %d at %d\n",result,run);return 1;}
 }
 puts("1000 bounded randomized meshes passed address/undefined/float-cast sanitizers");
}
