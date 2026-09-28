import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const [sourceRoot, referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/geospatial_reference.mjs SOURCE REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const ts = require('typescript');
const three = require('three');
if (ts.version !== '5.9.2' || three.REVISION !== '184' ||
    JSON.parse(fs.readFileSync(path.join(referenceRoot, 'node_modules/tiny-invariant/package.json'))).version !== '1.3.3') {
  throw new Error('Reference dependency versions differ from the pinned fixture environment');
}
const root = path.resolve(sourceRoot);
const inventory = JSON.parse(fs.readFileSync(new URL('./reference/inventory.json', import.meta.url)));
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
const { Geodetic } = load('packages/core/src/Geodetic');
const { Ellipsoid } = load('packages/core/src/Ellipsoid');
const { Rectangle } = load('packages/core/src/Rectangle');
const { TileCoordinate } = load('packages/core/src/TileCoordinate');
const { TilingScheme } = load('packages/core/src/TilingScheme');
const { PointOfView } = load('packages/core/src/PointOfView');
const rad = x => x * Math.PI / 180;
const geodesy = [];
for (const radii of [[6378137,6378137,6356752.3142451793],[7000000,6500000,6000000]]) {
  const ellipsoid = new Ellipsoid(...radii);
  for (const longitude of [-180,-73.9709,0,138.5973,180]) for (const latitude of [-90,-41,0,40.7589,90]) for (const height of [-500,0,4e5,3.6e7]) {
    const coordinate = new Geodetic(rad(longitude),rad(latitude),height);
    const position = coordinate.toECEF(undefined,{ellipsoid});
    const east = new three.Vector3(), north = new three.Vector3(), up = new three.Vector3();
    ellipsoid.getEastNorthUpVectors(position,east,north,up);
    geodesy.push({radii,coordinate:coordinate.toArray(),position:position.toArray(),surface:ellipsoid.projectOnSurface(position).toArray(),normal:ellipsoid.getSurfaceNormal(position).toArray(),inverse:new Geodetic().setFromECEF(position,{ellipsoid}).toArray(),east:east.toArray(),north:north.toArray(),up:up.toArray(),enu:ellipsoid.getEastNorthUpFrame(position).toArray(),nue:ellipsoid.getNorthUpEastFrame(position).toArray()});
  }
}
const projection = [[1,2,3],[1000,0,0],[6378137,0,0]].map(p => ({position:p,surface:Ellipsoid.WGS84.projectOnSurface(new three.Vector3(...p)).toArray()}));
const rectangles = [[-Math.PI,-Math.PI/2,Math.PI,Math.PI/2],[rad(170),rad(-30),rad(-170),rad(30)],[-1,-.5,2,1]];
const tiling = rectangles.map(bounds => {
  const rectangle = new Rectangle(...bounds),scheme = new TilingScheme(2,1,rectangle);
  return {bounds,width:rectangle.width,height:rectangle.height,points:[[0,0],[.5,.5],[1,1]].map(xy=>({xy,coordinate:rectangle.at(...xy).toArray()})),tiles:[0,1,4,12].flatMap(z=>[-180,-175,0,175,180].map(lon=>{
    const coordinate = new Geodetic(rad(lon),0),tile=scheme.getTile(coordinate,z);
    return {coordinate:coordinate.toArray(),z,tile:tile.toArray(),rectangle:scheme.getRectangle(tile).toArray(),size:scheme.getSize(z).toArray()};
  }))};
});
const descendants = [[0,0,0],[3,4,3],[-1,-1,2]].map(values=>{
  const tile=new TileCoordinate(...values);
  return {tile:values,parent:tile.getParent().toArray(),levels:[0,1,2,3].map(depth=>({depth,children:[...tile.traverseChildren(depth)].map(c=>c.toArray())}))};
});
const views=[];
for (const coordinate of [[-73.9709,40.7589],[138.5973,35.2138],[0,0],[27,89.999]]) for (const heading of [-155,0,90]) for (const roll of [0,23]) {
  const target=new Geodetic(rad(coordinate[0]),rad(coordinate[1])).toECEF();
  const view=new PointOfView(3000,rad(heading),rad(-35),rad(roll));
  const eye=new three.Vector3(),quaternion=new three.Quaternion(),surfaceUp=new three.Vector3();
  view.decompose(target,eye,quaternion,surfaceUp);
  const camera=new three.PerspectiveCamera(50,1,.1,1e8);
  camera.position.copy(eye);camera.quaternion.copy(quaternion);camera.updateMatrixWorld();
  const hit=new three.Vector3(),inverse=new PointOfView().setFromCamera(camera,undefined,hit);
  const worldUp=new three.Vector3(0,1,0).applyQuaternion(quaternion);
  views.push({input:[view.distance,view.heading,view.pitch,view.roll],target:target.toArray(),eye:eye.toArray(),quaternion:quaternion.toArray(),surfaceUp:surfaceUp.toArray(),worldUp:worldUp.toArray(),hit:inverse?hit.toArray():null,inverse:inverse?[inverse.distance,inverse.heading,inverse.pitch,inverse.roll]:null});
}
const ellipsoidExtras = geodesy.filter(row=>row.radii[0]===row.radii[1]).slice(0,20).map(row=>{
  const ellipsoid=new Ellipsoid(...row.radii),p=new three.Vector3(...row.position),d=new three.Vector3(1,2,-1).normalize();
  return {position:row.position,direction:d.toArray(),radius:1e6,center:ellipsoid.getOsculatingSphereCenter(p,1e6).toArray(),horizon:ellipsoid.getNormalAtHorizon(p,d).toArray()};
});
const data={revision:inventory.revision,dependencies:{three:'0.184.0',typescript:'5.9.2','tiny-invariant':'1.3.3'},sourceFiles:[...loaded.keys()].map(file=>({path:file,gitBlob:hashes.get(file)})),geodesy,projection,tiling,descendants,views,ellipsoidExtras};
fs.mkdirSync(path.dirname(output),{recursive:true});
fs.writeFileSync(output,JSON.stringify(data,null,2)+'\n');
console.log(JSON.stringify({geodesy:geodesy.length,tiling:tiling.reduce((n,v)=>n+v.tiles.length,0),views:views.length}));
