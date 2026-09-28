// Execute the supplied celestialDirections.ts against its pinned dependencies.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const sourceRoot=process.argv[2] ?? '/Users/rexraphael/Work/TwinOS/three-geospatial-main';
const referenceRoot=process.argv[3] ?? '/tmp/geospatial-reference';
const require=createRequire(path.join(referenceRoot,'package.json'));
const ts=require('typescript'),three=require('three'),astronomy=require('astronomy-engine');
const version=JSON.parse(fs.readFileSync(path.join(referenceRoot,'node_modules/astronomy-engine/package.json'))).version;
if(version!=='2.1.19'||three.REVISION!=='184') throw new Error('Reference dependencies changed');
const file='packages/atmosphere/src/celestialDirections.ts';
const source=fs.readFileSync(path.join(sourceRoot,file),'utf8');
const inventory=JSON.parse(fs.readFileSync('docs/parity/inventory.json'));
const hash=crypto.createHash('sha1').update(`blob ${Buffer.byteLength(source)}\0`).update(source).digest('hex');
if(inventory.files.find(f=>f.path===file).gitBlob!==hash) throw new Error('Source snapshot changed');
const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const module={exports:{}};
vm.runInThisContext(`(function(require,module,exports){${code}\n})`)(name=>name==='@takram/three-geospatial'?{radians:x=>x*Math.PI/180}:require(name),module,module.exports);
const api=module.exports,cases=[];
for(const date of ['1600-01-01T00:00:00Z','1900-01-01T00:00:00Z','2000-01-01T12:00:00Z','2026-03-20T14:46:00Z','2026-06-21T08:24:00Z','2026-09-23T00:05:00Z','2026-12-21T20:50:00Z','2026-09-27T23:59:59.999Z','2026-09-28T00:00:00Z','2100-01-01T00:00:00Z','2400-12-31T12:00:00Z']) {
  for(const observer of [null,[6378137,0,0],[1335500,-4655500,4139000],[0,0,6356752.314],[7000000,0,0]]) {
    const time=new Date(date),p=observer?new three.Vector3(...observer):undefined;
    const sun=astronomy.GeoVector(astronomy.Body.Sun,time,false),moon=astronomy.GeoVector(astronomy.Body.Moon,time,false);
    const astroTime=new astronomy.AstroTime(time);
    cases.push({date,observer,ut:astroTime.ut,tt:astroTime.tt,siderealHours:astronomy.SiderealTime(time),sunDistanceMeters:sun.Length()*astronomy.KM_PER_AU*1000,moonDistanceMeters:moon.Length()*astronomy.KM_PER_AU*1000,sunECI:api.getSunDirectionECI(time,undefined,p).toArray(),moonECI:api.getMoonDirectionECI(time,undefined,p).toArray(),sunECEF:api.getSunDirectionECEF(time,undefined,p).toArray(),moonECEF:api.getMoonDirectionECEF(time,undefined,p).toArray(),eciToEcef:api.getECIToECEFRotationMatrix(time).toArray(),moonFixedToEci:api.getMoonFixedToECIRotationMatrix(time).toArray()});
  }
}
const timeCases=[-9999,-501,-500,0,499,500,1599,1600,1699,1700,1799,1800,1859,1860,1899,1900,1919,1920,1940,1941,1960,1961,1985,1986,2004,2005,2049,2050,2149,2150,9999].map(year=>{
  const date=new Date('2000-01-01T00:00:00Z'); date.setUTCFullYear(year);
  const t=new astronomy.AstroTime(date);return {date:date.toISOString(),ut:t.ut,tt:t.tt,deltaT:astronomy.DeltaT_EspenakMeeus(t.ut)};
});
fs.mkdirSync('packages/zyren_geospatial/test/fixtures/atmosphere' ,{recursive:true});
fs.writeFileSync('packages/zyren_geospatial/test/fixtures/atmosphere/celestial.json',JSON.stringify({revision:inventory.revision,source:{path:file,gitBlob:hash},dependencies:{three:'0.184.0',astronomyEngine:version},astronomySha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(referenceRoot,'node_modules/astronomy-engine/astronomy.js'))).digest('hex'),timeCases,cases},null,2)+'\n');
console.log(`${cases.length} celestial cases`);
