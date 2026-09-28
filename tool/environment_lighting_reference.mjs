// Independent hemisphere quadrature of the pinned Three r184 BRDF.
import fs from 'node:fs';
import { D,V,F } from './pbr_reference.mjs';
const size=32, bins=1024, samples=[];
for (const y of [15,31]) for (const x of [3,15,31]) {
  const nv=(x+.5)/size, rough=(y+.5)/size, vx=Math.sqrt(1-nv*nv);
  let a=0,b=0;
  for(let j=0;j<bins;j++) {
    const nl=(j+.5)/bins,s=Math.sqrt(1-nl*nl);
    for(let k=0;k<bins;k++) {
      const phi=(k+.5)*2*Math.PI/bins,lx=s*Math.cos(phi),ly=s*Math.sin(phi);
      const hx=lx+vx,hy=ly,hz=nl+nv,len=Math.hypot(hx,hy,hz);
      const nh=hz/len,vh=(vx*hx+nv*hz)/len;
      const weight=D(rough*rough,nh)*V(rough*rough,nl,nv)*nl;
      const f=F(0,1,vh);
      a+=(1-f)*weight;b+=f*weight;
    }
  }
  samples.push({x,y,nv,roughness:rough,brdf:[a*2*Math.PI/(bins*bins),b*2*Math.PI/(bins*bins)]});
}
fs.writeFileSync('test_assets/rendering/pbr/environment.json',JSON.stringify({reference:'Three r184 scalar BRDF, independent 1024 by 1024 hemisphere quadrature',size,samples},null,2)+'\n');
