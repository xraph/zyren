// CPU evaluation of Three.js 0.184.0 FXAAShader's luminance and edge equations.
// The reference consumes display-encoded opaque colors, as the upstream pass does.
import fs from 'node:fs';
import {createHash} from 'node:crypto';
const root=process.env.THREE_REFERENCE_ROOT ?? '/tmp/geospatial-reference/node_modules/three';
const source=fs.readFileSync(`${root}/examples/jsm/shaders/FXAAShader.js`);
const version=JSON.parse(fs.readFileSync(`${root}/package.json`)).version;
if(version!=='0.184.0') throw new Error(`Unexpected Three version: ${version}`);
const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x));
const mix=(a,b,t)=>a.map((v,i)=>v*(1-t)+b[i]*t);
const luminance=c=>c[0]*.3+c[1]*.59+c[2]*.11;
const srgb=x=>x<=.0031308?12.92*x:1.055*x**(1/2.4)-.055;
function reference(input,width,height) {
  function sample(x,y) {
    x-=.5; y-=.5;
    const bx=Math.floor(x),by=Math.floor(y),fx=x-bx,fy=y-by;
    const p=(x,y)=>input[clamp(y,0,height-1)*width+clamp(x,0,width-1)];
    return mix(mix(p(bx,by),p(bx+1,by),fx),mix(p(bx,by+1),p(bx+1,by+1),fx),fy);
  }
  const lum=(x,y)=>luminance(sample(x,y));
  function pixel(x,y) {
    const m=lum(x,y),n=lum(x,y+1),e=lum(x+1,y),s=lum(x,y-1),w=lum(x-1,y);
    const highest=Math.max(m,n,e,s,w),lowest=Math.min(m,n,e,s,w),contrast=highest-lowest;
    if(contrast<Math.max(.0312,.063*highest)) return sample(x,y);
    const ne=lum(x+1,y+1),nw=lum(x-1,y+1),se=lum(x+1,y-1),sw=lum(x-1,y-1);
    const f=clamp(Math.abs((2*(n+e+s+w)+ne+nw+se+sw)/12-m)/contrast);
    const pixelBlend=(f*f*(3-2*f))**2;
    const horizontal=2*Math.abs(n+s-2*m)+Math.abs(ne+se-2*e)+Math.abs(nw+sw-2*w);
    const vertical=2*Math.abs(e+w-2*m)+Math.abs(ne+nw-2*n)+Math.abs(se+sw-2*s);
    const isHorizontal=horizontal>=vertical;
    const positive=isHorizontal?n:e,negative=isHorizontal?s:w;
    const pg=Math.abs(positive-m),ng=Math.abs(negative-m);
    const step=pg<ng?-1:1,opposite=pg<ng?negative:positive;
    const edgeLuminance=(m+opposite)*.5,gradientThreshold=Math.max(pg,ng)*.25;
    const start=[x+(isHorizontal?0:step*.5),y+(isHorizontal?step*.5:0)];
    const along=isHorizontal?[1,0]:[0,1];
    function endpoint(sign) {
      let distance=0,delta=0,found=false;
      for(const size of [1,1.5,2,2,2,4]) {
        distance+=size;
        delta=lum(start[0]+sign*along[0]*distance,start[1]+sign*along[1]*distance)-edgeLuminance;
        if(Math.abs(delta)>=gradientThreshold) {found=true;break;}
      }
      if(!found) distance+=8;
      return {distance,delta};
    }
    const p=endpoint(1),q=endpoint(-1),nearest=p.distance<=q.distance?p:q;
    const edgeBlend=(nearest.delta>=0)===(m-edgeLuminance>=0)?0:.5-nearest.distance/(p.distance+q.distance);
    const blend=Math.max(pixelBlend,edgeBlend);
    return sample(x+(isHorizontal?0:step*blend),y+(isHorizontal?step*blend:0));
  }
  return Array.from({length:width*height},(_,i)=>pixel(i%width+.5,Math.floor(i/width)+.5)).flat().map(v=>Math.round(255*clamp(v)));
}
const width=32,height=24,cases=[];
for(const pattern of ['diagonal','thin','low-contrast','hdr']) {
  const inputs=Array.from({length:width*height},(_,i)=>{
    const x=i%width,y=Math.floor(i/width);
    const mask=pattern==='thin'? (x===10||Math.abs(x-y*.7-8)<.65) : x>y*.61+8;
    const c=pattern==='hdr'?(mask?[8,2,.5,1]:[.125,.03125,0,1]) : pattern==='low-contrast'?(mask?[.25,.25,.25,1]:[.25390625,.25390625,.25390625,1]):(mask?[.75,.5,.125,1]:[.0625,.125,.25,1]);
    return c;
  });
  const toneMapping=pattern==='hdr'?'reinhard':'none';
  const display=inputs.map(c=>c.map((v,i)=>i===3?v:srgb(toneMapping==='reinhard'?v/(1+v):v)));
  cases.push({name:pattern,toneMapping,input:inputs.flat(),expected:reference(display,width,height)});
}
fs.mkdirSync('test_assets/rendering/effects',{recursive:true});
fs.writeFileSync('test_assets/rendering/effects/fxaa.json',JSON.stringify({reference:`Three.js ${version} FXAAShader`,sha256:createHash('sha256').update(source).digest('hex'),width,height,cases})+'\n');
