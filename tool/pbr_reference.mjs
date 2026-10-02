// Numerical oracle extracted from Three r184's scalar shader functions.
import fs from 'node:fs';
const root = '/tmp/geospatial-reference/node_modules/three';
const pkg = JSON.parse(fs.readFileSync(`${root}/package.json`));
if (pkg.version !== '0.184.0') throw new Error('Expected Three r184');
const chunk = name => fs.readFileSync(`${root}/src/renderers/shaders/ShaderChunk/${name}.glsl.js`, 'utf8');
function scalar(source, name, parameters) {
  const match = source.match(new RegExp(`float ${name}\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\}`));
  if (!match) throw new Error(name);
  const body = match[1].replace(/\/\/[^\n]*/g, '').replace(/\bfloat\b/g, 'let');
  return Function(...parameters, `const pow2=x=>x*x, sqrt=Math.sqrt, max=Math.max, exp2=x=>2**x, RECIPROCAL_PI=1/Math.PI, EPSILON=1e-6; ${body}`);
}
const D = scalar(chunk('lights_physical_pars_fragment'), 'D_GGX', ['alpha','dotNH']);
const V = scalar(chunk('lights_physical_pars_fragment'), 'V_GGX_SmithCorrelated', ['alpha','dotNL','dotNV']);
const F = scalar(chunk('common'), 'F_Schlick', ['f0','f90','dotVH']);
const samples=[];
for(const roughness of [.1,.2,.5,1]) for(const metallic of [0,.5,1]) {
  const base=[.5,.2,.1], r=Math.max(roughness,.0525);
  const radiance=base.map(c=>c*(1-metallic)/Math.PI + F(.04*(1-metallic)+c*metallic,1,1)*V(r*r,1,1)*D(r*r,1));
  samples.push({roughness,metallic,base,radiance});
}
fs.mkdirSync('test_assets/rendering/pbr',{recursive:true});
fs.writeFileSync('test_assets/rendering/pbr/direct.json',JSON.stringify({reference:'three@0.184.0 scalar GGX, correlated Smith and Schlick functions; single scattering, normal incidence',samples},null,2)+'\n');

export {D,V,F};
