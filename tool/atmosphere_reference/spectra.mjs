// Run the pinned source CIE helper and independent dense midpoint integration.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const [sourceRoot,referenceRoot,output]=process.argv.slice(2);
if(!output) throw new Error('Usage: node tool/atmosphere_reference/spectra.mjs SOURCE REFERENCE OUTPUT');
const require=createRequire(path.resolve(referenceRoot,'package.json'));
const ts=require('typescript'),three=require('three');
if(ts.version!=='5.9.2'||three.REVISION!=='184') throw new Error('Reference dependencies changed');
const file='packages/atmosphere/src/helpers/colorMatchingFunctions.ts';
const text=fs.readFileSync(path.join(sourceRoot,file),'utf8');
const hash=crypto.createHash('sha1').update(`blob ${Buffer.byteLength(text)}\0`).update(text).digest('hex');
const inventory=JSON.parse(fs.readFileSync(new URL('../reference/inventory.json',import.meta.url)));
if(inventory.files.find(f=>f.path===file).gitBlob!==hash) throw new Error('Source helper changed');
const code=ts.transpileModule(text,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const module={exports:{}};
vm.runInThisContext(`(function(require,module,exports){${code}\n})`)(require,module,module.exports);
const matching=module.exports.getCIEColorMatchingFunctionValue;
const lookup=[];
for(let nm=355;nm<=835;nm+=1.25) lookup.push({nm,xyz:matching(nm,new three.Vector3()).toArray()});
const spectra=[
  {name:'flat',wavelengths:[360,830],values:[1,1]},
  {name:'sloped',wavelengths:[365.3,610.2,825.7],values:[.2,3,1]},
  {name:'blue band',wavelengths:[430,435,440],values:[0,1,0]},
  {name:'narrow green',wavelengths:[554.125,555.375,556.125],values:[0,2,0]},
  {name:'zero',wavelengths:[360,830],values:[0,0]},
];
for(const spectrum of spectra) {
  const {wavelengths:w,values:v}=spectrum;
  function power(nm) {
    if(nm<w[0]||nm>w.at(-1)) return 0;
    let i=0;while(i<w.length-2&&w[i+1]<nm)i++;
    const t=(nm-w[i])/(w[i+1]-w[i]);return v[i]*(1-t)+v[i+1]*t;
  }
  const xyz=new three.Vector3(),scratch=new three.Vector3(),steps=94000,step=470/steps;
  for(let i=0;i<steps;i++) {const nm=360+(i+.5)*step;xyz.addScaledVector(matching(nm,scratch),power(nm)*step*683);}
  const matrix=new three.Matrix3(3.2406255,-1.537208,-.4986286,-.9689307,1.8757561,.0415175,.0557101,-.2040211,1.0569959);
  spectrum.xyz=xyz.toArray();spectrum.rgb=xyz.clone().applyMatrix3(matrix).toArray();
}
fs.writeFileSync(output,JSON.stringify({source:{file,gitBlob:hash},quadrature:'94000 midpoint samples over 360-830 nm; 683 lm/W',lookup,spectra},null,2)+'\n');
console.log(`${lookup.length} matching-function cases, ${spectra.length} spectra`);
