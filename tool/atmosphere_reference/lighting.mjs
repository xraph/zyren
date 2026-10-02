import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const [sourceRoot, referenceRoot, assets, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/atmosphere_reference/lighting.mjs SOURCE REFERENCE ASSETS OUTPUT');
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
    name => name === '@takram/three-geospatial' ? core() : name.startsWith('.') ? load(path.posix.join(path.posix.dirname(file), name)) : require(name), module, module.exports);
  return module.exports;
}

function core() {
  return {...load('packages/core/src/Ellipsoid'), ...load('packages/core/src/math'),
    ...load('packages/core/src/typedArray'), ...load('packages/core/src/types')};
}
const {Ellipsoid} = core();
const {Geodetic} = load('packages/core/src/Geodetic');
const {getSunLightColor} = load('packages/atmosphere/src/getSunLightColor');
const {SkyLightProbe} = load('packages/atmosphere/src/SkyLightProbe');
const {AtmosphereParameters} = load('packages/atmosphere/src/AtmosphereParameters');
const atmosphere = AtmosphereParameters.DEFAULT;
const assetHashes={};
function table(name,width,height) {
  const bytes=fs.readFileSync(path.join(assets,name+'.bin'));
  const sha=crypto.createHash('sha256').update(bytes).digest('hex');
  const pointer=fs.readFileSync(path.join(root,'packages/atmosphere/assets',name+'.bin'),'utf8');
  if(!pointer.includes('oid sha256:'+sha)||!pointer.includes('size '+bytes.length)) throw new Error('Asset changed');
  assetHashes[name]=sha;
  const copy=new Uint8Array(bytes);
  return new three.DataTexture(new Uint16Array(copy.buffer),width,height,three.RGBAFormat,three.HalfFloatType);
}
const transmittance=table('transmittance',256,64),irradiance=table('irradiance',64,16);
const cases=[];
for(const [lon,lat,height] of [[0,0,10],[-74,43,10000],[140,85,400000],[0,0,36000000]]) {
  const position=new Geodetic(lon*Math.PI/180,lat*Math.PI/180,height).toECEF();
  const normal=Ellipsoid.WGS84.getSurfaceNormal(position);
  const tangent=new three.Vector3(0,0,1).cross(normal).normalize();
  for(const mus of [-1,-.2,-.01,0,.1,1]) for(const correctAltitude of [false,true]) {
    const sun=normal.clone().multiplyScalar(mus).addScaledVector(tangent,Math.sqrt(1-mus*mus));
    const color=getSunLightColor(transmittance,position,sun,undefined,{correctAltitude});
    const probe=new SkyLightProbe({irradianceTexture:irradiance,sunDirection:sun,correctAltitude});
    probe.position.copy(position);probe.update();
    cases.push({position:position.toArray(),sun:sun.toArray(),correctAltitude,
      sunIrradiance:color.toArray(),skyIrradiance:probe.sh.coefficients[0].clone().multiplyScalar(Math.sqrt(Math.PI)).toArray(),
      coefficients:probe.sh.coefficients.slice(0,4).map(v=>v.toArray())});
  }
}
fs.writeFileSync(output,JSON.stringify({revision:inventory.revision,sourceFiles:[...loaded.keys()],assetHashes,
  dependencies:{three:'0.184.0',typescript:ts.version,float16:'3.9.3'},cases},null,2)+'\n');
console.log(cases.length+' source lighting cases');
