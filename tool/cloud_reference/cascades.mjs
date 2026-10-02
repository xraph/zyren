import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const [sourceRoot, referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/cloud_reference/defaults.mjs SOURCE REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const ts = require('typescript');
const three = require('three');
if (ts.version !== '5.9.2' || three.REVISION !== '184' ||
    JSON.parse(fs.readFileSync(path.join(referenceRoot, 'node_modules/tiny-invariant/package.json'))).version !== '1.3.3') {
  throw new Error('Reference dependency versions differ from the pinned fixture environment');
}
if (JSON.parse(fs.readFileSync(path.join(referenceRoot, 'node_modules/@petamoriken/float16/package.json'))).version !== '3.9.3') throw new Error('Reference float16 dependency changed');
const root = path.resolve(sourceRoot);
const inventory = JSON.parse(fs.readFileSync(new URL('../reference/inventory.json', import.meta.url)));
const hashes = new Map(inventory.files.map(file => [file.path, file.gitBlob]));
const loaded = new Map();
function load(relative) {
  const file = relative.endsWith('.ts') ? relative : `${relative}.ts`;
  if (loaded.has(file)) return loaded.get(file).exports;
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  const sha = crypto.createHash('sha1').update(`blob ${Buffer.byteLength(text)}\0`).update(text).digest('hex');
  if (sha !== hashes.get(file)) throw new Error(`Reference changed: ${file}`);
  const module = { exports: {} };
  loaded.set(file, module);
  const code = ts.transpileModule(text, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true } }).outputText;
  vm.runInThisContext(`(function(require,module,exports){${code}\n})`, { filename: file })(
    name => name === '@takram/three-geospatial' ? { lerp: (a,b,t) => a+(b-a)*t } : name.startsWith('.') ? load(path.posix.join(path.posix.dirname(file), name)) : require(name), module, module.exports);
  return module.exports;
}

const {CascadedShadowMaps}=load('packages/clouds/src/CascadedShadowMaps');
const cases=[];
for(const orthographic of [false,true])for(const i of [0,1,2]){
 const position=i===0?[0,0,1000]:i===1?[6378137,1000,2000]:[-2000,100,300];
 const target=position.map((v,j)=>v+[200,-100,-2000][j]);
 const sun=new three.Vector3(...[[.3,.8,.5],[-.3,.1,.7],[0,1,0]][i]).normalize();
 const near=orthographic&&i===2?0:1,far=300000;
 const camera=orthographic?new three.OrthographicCamera(-1500,2500,2000,-1000,near,far):new three.PerspectiveCamera(60,1.5,near,far);
 camera.position.fromArray(position);camera.lookAt(new three.Vector3(...target));camera.zoom=i===1?2:1;camera.updateProjectionMatrix();camera.updateMatrixWorld();
 const options={cascadeCount:i===0?2:3,mapSize:new three.Vector2(256,256),maxFar:200000,margin:100,fade:true,splitMode:near===0?'uniform':'practical'};
 const maps=new CascadedShadowMaps(options);maps.update(camera,sun,50000);
 cases.push({orthographic,position,target,sun:sun.toArray(),near,far,zoom:camera.zoom,splitMode:options.splitMode,count:options.cascadeCount,result:maps.cascades.map(c=>({interval:c.interval.toArray(),matrix:c.matrix.toArray(),inverse:c.inverseMatrix.toArray(),projection:c.projectionMatrix.toArray(),view:c.viewMatrix.toArray(),inverseView:c.inverseViewMatrix.toArray()}))});
}
fs.writeFileSync(output,JSON.stringify({revision:inventory.revision,sourceFiles:[...loaded.keys()],cases},null,2)+'\n');
console.log(cases.length+' original cascade cases');
