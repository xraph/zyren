// node generate_curves.mjs /path/to/three-0.184-core.mjs > catmull_rom.json
import { pathToFileURL } from 'node:url';
const { CatmullRomCurve3, Vector3 } = await import(pathToFileURL(process.argv[2]));
const controls = [[0,0,0],[1,2,-1],[3,1,2],[4,0,0]];
const points = controls.map(p => new Vector3(...p));
const cases = [];
for (const closed of [false,true]) for (const type of ['centripetal','chordal','catmullrom']) {
  const curve = new CatmullRomCurve3(points,closed,type,.3);
  cases.push({closed,type,samples:[.125,.37,.71,.93].map(t => ({t,point:curve.getPoint(t).toArray()}))});
}
console.log(JSON.stringify({source:'three@0.184.0',controls,tension:.3,cases},null,2));
