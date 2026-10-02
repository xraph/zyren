import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
const [referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/globe_reference.mjs REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json')), three = require('three');
const root = path.resolve(referenceRoot, 'node_modules/3d-tiles-renderer');
if (three.REVISION !== '184' || JSON.parse(fs.readFileSync(path.join(root,'package.json'))).version !== '0.4.24') throw new Error('Reference version mismatch');
const { GlobeControls } = await import(pathToFileURL(path.join(root,'src/three/renderer/controls/GlobeControls.js')));
globalThis.window = {devicePixelRatio: 1};
class Surface {
  style={}; clientWidth=800; clientHeight=600; listeners=new Map();
  addEventListener(n,cb){if(!this.listeners.has(n))this.listeners.set(n,new Set());this.listeners.get(n).add(cb);}
  removeEventListener(n,cb){this.listeners.get(n)?.delete(cb);}
  getRootNode(){return this;} getBoundingClientRect(){return {left:0,top:0,width:this.clientWidth,height:this.clientHeight};}
  setPointerCapture(){} releasePointerCapture(){}
  emit(n,e){for(const cb of this.listeners.get(n)??[])cb({type:n,preventDefault(){},...e});}
}
const p=(type,x,y,extra={})=>({type,x,y,...extra});
// Avoid upstream's non-unit quaternion at the top-down tilt clamp.
// Dart tests cover that boundary separately with orthonormal camera invariants.
const actions=[p('down',400,300),p('move',420,315),p('move',435,325),{type:'up'},{type:'tick',count:8},p('down',400,300,{buttons:2}),p('move',425,303),{type:'up'},{type:'tick',count:8},p('hover',400,300),p('wheel',400,300,{dy:-120}),p('wheel',400,300,{dy:240}),p('hover',620,280),p('wheel',620,280,{dy:-80}),p('wheel',620,280,{dy:160}),p('down',400,300),p('move',1200,-100),{type:'up'},{type:'tick',count:8},{type:'resize',width:390,height:700},p('hover',195,350),p('wheel',195,350,{dy:300}),p('wheel',195,350,{dy:-300}),p('down',155,350,{touch:true}),p('down',235,350,{touch:true,id:2}),{type:'batch',points:[p('move',145,350,{touch:true}),p('move',245,350,{touch:true,id:2})]},{type:'up'},p('down',155,350,{touch:true}),p('down',235,350,{touch:true,id:2}),{type:'batch',points:[p('move',160,354,{touch:true}),p('move',240,354,{touch:true,id:2})]},{type:'up'}];
const cases=[];
for(const hz of [30,60,120]) for(const kind of ['perspective','orthographic']) for(const near of [false,true]) for(const transformed of [false,true]) {
  const radius=6378137, surface=new Surface(), frame=new three.Group();
  if(transformed){frame.position.set(1e7,-2e7,3e7);frame.quaternion.setFromAxisAngle(new three.Vector3(.2,.5,1).normalize(),.7);}
  frame.updateMatrixWorld();
  const camera=kind==='perspective'?new three.PerspectiveCamera(50,800/600,.1,1e9):new three.OrthographicCamera(-800,800,600,-600,0,1e9);
  const pos=new three.Vector3(radius*(near?1.08:3),radius*.1,radius*.1).applyMatrix4(frame.matrixWorld);
  const target=new three.Vector3(near?radius:0,0,0).applyMatrix4(frame.matrixWorld);
  camera.position.copy(pos);camera.up.set(0,0,1).transformDirection(frame.matrixWorld);camera.lookAt(target);if(kind==='orthographic')camera.zoom=near?.003:.0001;camera.updateProjectionMatrix();camera.updateMatrixWorld();
  const initial={position:pos.toArray(),target:target.toArray(),up:camera.up.toArray(),zoom:camera.zoom,frame:frame.matrixWorld.toArray()};
  const controls=new GlobeControls(new three.Scene(),camera,surface);controls.setEllipsoid(null,frame);controls.enableDamping=true;controls.update(1/hz);
  const events=[];for(const n of ['start','change','end'])controls.addEventListener(n,()=>events.push(n));
  const trace=[];
  function capture(action){trace.push({action,position:camera.position.toArray(),forward:new three.Vector3(0,0,-1).applyQuaternion(camera.quaternion).toArray(),up:new three.Vector3(0,1,0).applyQuaternion(camera.quaternion).toArray(),zoom:camera.zoom,near:camera.near,far:camera.far,state:controls.state,events:events.splice(0)});}
  capture({type:'initial'});
  for(const action of actions){
    if(action.type==='tick'){for(let i=0;i<action.count;i++){controls.update(1/hz);capture({type:'tick'});}continue;}
    if(action.type==='resize'){surface.clientWidth=action.width;surface.clientHeight=action.height;if(kind==='perspective')camera.aspect=action.width/action.height;camera.updateProjectionMatrix();}
    else { for(const a of action.type==='batch'?action.points:[action]) surface.emit(({down:'pointerdown',move:'pointermove',hover:'pointermove',up:'pointerup',wheel:'wheel'})[a.type],{clientX:a.x??0,clientY:a.y??0,pointerId:a.id??1,pointerType:a.touch?'touch':'mouse',buttons:a.buttons??1,deltaY:a.dy??0,deltaMode:0}); }
    await Promise.resolve();controls.update(1/hz);capture(action);
  }
  cases.push({hz,kind,near,transformed,initial,radii:controls.ellipsoid.radius.toArray(),trace});controls.dispose();
}
fs.writeFileSync(output,JSON.stringify({source:'3d-tiles-renderer 0.4.24',cases})+'\n');
