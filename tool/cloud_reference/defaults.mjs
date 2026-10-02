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
    name => name.startsWith('.') ? load(path.posix.join(path.posix.dirname(file), name)) : require(name), module, module.exports);
  return module.exports;
}

const {CloudLayers} = load('packages/clouds/src/CloudLayers');
const {CloudLayer} = load('packages/clouds/src/CloudLayer');
const {defaults,qualityPresets} = load('packages/clouds/src/qualityPresets');
const {createCloudParameterUniforms,createCloudLayerUniforms,updateCloudLayerUniforms} = load('packages/clouds/src/uniforms');
const cases=[];
for(const options of [undefined,[{altitude:0,height:1},{altitude:2,height:1},{altitude:4,height:1},{altitude:6,height:1}],
 [{altitude:0,height:3},{altitude:2,height:1},{altitude:4,height:2},{altitude:6,height:1}],
 [{altitude:0,height:3},{altitude:2,height:0},{altitude:4,height:4},{altitude:6,height:1}],
 [{altitude:10,height:0},{altitude:10,height:0},{altitude:12,height:0},{altitude:12,height:0}],
 [{altitude:1,height:1,shadow:true},{altitude:2,height:1,shadow:true},{altitude:3,height:1},{altitude:4,height:1}]]) {
 const layers=options ? new CloudLayers(options) : CloudLayers.DEFAULT.clone();
 const uniforms=createCloudLayerUniforms();updateCloudLayerUniforms(uniforms,layers);
 const values=Object.fromEntries(Object.entries(uniforms).map(([k,v])=>[k,v.value?.toArray?v.value.toArray():v.value]));
 cases.push({layers:[...layers],values});
}
const params=createCloudParameterUniforms({localWeatherRepeat:new three.Vector2(100,100),localWeatherOffset:new three.Vector2(),
 shapeRepeat:new three.Vector3(.0003,.0003,.0003),shapeOffset:new three.Vector3(),shapeDetailRepeat:new three.Vector3(.006,.006,.006),
 shapeDetailOffset:new three.Vector3(),turbulenceRepeat:new three.Vector2(20,20),localWeatherTexture:null,shapeTexture:null,shapeDetailTexture:null,turbulenceTexture:null});
fs.writeFileSync(output,JSON.stringify({revision:inventory.revision,sourceFiles:[...loaded.keys()],layerDefault:new CloudLayer(),
 parameters:Object.fromEntries(Object.entries(params).map(([k,v])=>[k,v.value?.toArray?v.value.toArray():v.value])),
 qualityPresets:JSON.parse(JSON.stringify(qualityPresets),(k,v)=>k==='mapSize'?[v.x,v.y]:v),cases},null,2)+'\n');
console.log(cases.length+' cloud layer cases');
