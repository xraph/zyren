// Evaluate the original source TSL filter expressions with a CPU texture host.
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=path.resolve(__dirname,'../..'),src=path.resolve(process.argv[2]),deps=path.resolve(process.argv[3]);
const ts=require(path.join(deps,'typescript'));
const inventory=JSON.parse(fs.readFileSync(path.join(root,'tool/reference/inventory.json')));
let currentUv=[0,0];
class N {
 constructor(v){this.v=Array.isArray(v)?v:[v];}
 op(b,f){b=node(b);const n=Math.max(this.v.length,b.v.length);return new N(Array.from({length:n},(_,i)=>f(this.v[i%this.v.length],b.v[i%b.v.length])));}
 add(...b){return b.reduce((a,b)=>a.op(b,(x,y)=>x+y),this);} sub(b){return this.op(b,(x,y)=>x-y);} mul(b){return this.op(b,(x,y)=>x*y);} div(b){return this.op(b,(x,y)=>x/y);}
 addAssign(...b){this.v=this.add(...b).v;return this;}
 greaterThanEqual(b){return this.op(b,(x,y)=>x>=y?1:0);} lessThanEqual(b){return this.op(b,(x,y)=>x<=y?1:0);}
 all(){return new N(this.v.every(v=>v!==0)?1:0);} and(b){return this.op(b,(x,y)=>x&&y?1:0);} toFloat(){return this;} toVertexStage(){return this;}
}
for(const swizzle of ['x','y','z','w','xy','zw','zy','xw','xyxy'])Object.defineProperty(N.prototype,swizzle,{get(){return new N([...swizzle].map(c=>this.v['xyzw'.indexOf(c)]));}});
const node=v=>v instanceof N?v:new N(v),vec=(n,args)=>{const v=args.flatMap(v=>node(v).v);return new N(v.length===1?Array(n).fill(v[0]):v);};
const tsl={add:(...v)=>v.map(node).reduce((a,b)=>a.add(b)),Fn:f=>()=>f(),uv:()=>new N(currentUv),vec2:(...v)=>vec(2,v),vec4:(...v)=>vec(4,v),uniform:node,mix:(a,b,t)=>node(a).mul(node(1).sub(t)).add(node(b).mul(t))};
class Base{constructor(input){this.inputNode=input;}}
const hashes={};
function load(name){const rel=`packages/core/src/webgpu/${name}.ts`,text=fs.readFileSync(path.join(src,rel),'utf8');const hash=crypto.createHash('sha1').update(`blob ${Buffer.byteLength(text)}\0`).update(text).digest('hex');if(hash!==inventory.files.find(v=>v.path===rel).gitBlob)throw Error('Source drift '+rel);hashes[rel]=hash;const code=ts.transpileModule(text,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;const exports={};new Function('require','exports',code+(name==='GaussianBlurNode'?'\nexports.GaussianBlurNode.referenceKernel=createGaussianKernel;':''))(m=>m==='three/tsl'?tsl:m==='tiny-invariant'?{default:v=>{if(!v)throw Error('invariant');}}:{[m.slice(2)]:Base},exports);return exports[name];}
const classes={};for(const kind of ['GaussianBlurNode','KawaseBlurNode','MipmapBlurNode','MipmapSurfaceBlurNode'])classes[kind]=load(kind);
function image(w,h,kind){return {w,h,data:Array.from({length:w*h},(_,i)=>kind==='constant'?[.25,.5,.75,1]:kind==='edge'?(i%w<2?[2,1,.5,.5]:[0,0,0,0]):i===Math.floor(h/2)*w+Math.floor(w/2)?[4,2,1,1]:[0,0,0,0])};}
function sampler(image){return {sample(uv){const [u,v]=uv.v,x=u*image.w-.5,y=v*image.h-.5,bx=Math.floor(x),by=Math.floor(y),fx=x-bx,fy=y-by;const out=[0,0,0,0];for(let j=0;j<2;j++)for(let i=0;i<2;i++){const p=image.data[Math.max(0,Math.min(image.h-1,by+j))*image.w+Math.max(0,Math.min(image.w-1,bx+i))];for(let k=0;k<4;k++)out[k]+=p[k]*(i?fx:1-fx)*(j?fy:1-fy);}return new N(out);}};}
function run(n,method,input,w,h,high){n.inputNode=sampler(input);n.inputTexelSize=new N([1/input.w,1/input.h]);n.downsampleNode=sampler(high??input);const data=[];for(let y=0;y<h;y++)for(let x=0;x<w;x++){currentUv=[(x+.5)/w,(y+.5)/h];data.push(n[method]().v);}return {w,h,data};}
const cases=[];
for(const kind of ['gaussian','kawase','mipmap','surface'])for(const pattern of ['constant','impulse','edge'])for(const [width,height]of [[16,12],[19,13]]){
 const input=image(width,height,pattern),name={gaussian:'GaussianBlurNode',kawase:'KawaseBlurNode',mipmap:'MipmapBlurNode',surface:'MipmapSurfaceBlurNode'}[kind],n=new classes[name](null,kind==='gaussian'?35:3);let output=input;
 if(kind==='gaussian'){n.direction=new N([1,0]);output=run(n,'setupOutputNode',output,width,height);n.direction=new N([0,1]);output=run(n,'setupOutputNode',output,width,height);}
 else{let w=Math.round(width*.5),h=Math.round(height*.5);const levels=[];for(let i=0;i<3;i++){w=Math.max(1,Math.round(w/2));h=Math.max(1,Math.round(h/2));output=run(n,'setupDownsampleNode',output,w,h);levels.push(output);}for(let i=1;i>=0;i--)output=run(n,'setupUpsampleNode',output,levels[i].w,levels[i].h,levels[i]);}
 cases.push({kind,pattern,width,height,levels:3,input:input.data.flat(),outputWidth:output.w,outputHeight:output.h,expected:output.data.flat()});
}
const kernels=[3,5,7,9,33,35,63].map(size=>{const k=classes.GaussianBlurNode.referenceKernel(size);return {size,weights:[...k.weights],offsets:[...k.offsets]};});
fs.writeFileSync(path.join(root,'packages/zyren_effects/test/fixtures/filters.json'),JSON.stringify({revision:inventory.revision,sourceFiles:hashes,kernels,cases})+'\n');console.log(cases.length+' original TSL filter cases');
