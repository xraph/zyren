import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const [referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/picking_reference.mjs REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const three = require('three');
if (three.REVISION !== '184') throw new Error('Expected Three r184');
const geometries = {
  plane: new three.PlaneGeometry(7, 5),
  box: new three.BoxGeometry(2, 3, 2),
  sphere: new three.SphereGeometry(1.5, 12, 8),
};
const geometryData = Object.fromEntries(Object.entries(geometries).map(([name, g]) => [name, {
  positions: Array.from(g.attributes.position.array),
  normals: Array.from(g.attributes.normal.array),
  indices: Array.from(g.index.array),
  uv0: Array.from(g.attributes.uv.array),
}]));
const meshes = [
  { geometry: 'plane', position: [0, 0, -2] },
  { geometry: 'box', position: [-1.5, 0, 0] },
  { geometry: 'sphere', position: [1.5, .5, 0] },
];
const cases = [];
for (const origin of [[0, 0, 0], [6378137, 100, 3000]]) {
  for (const scale of [[1, 1, 1], [2, .5, 1.5], [-1.3, 2, .75]]) {
    for (const projection of ['perspective', 'orthographic']) {
      const scene = new three.Scene();
      scene.position.fromArray(origin);
      const group = new three.Group();
      group.position.set(.2, -.3, .7);
      group.quaternion.setFromEuler(new three.Euler(.23, -.42, .17));
      group.scale.fromArray(scale);
      scene.add(group);
      const material = new three.MeshBasicMaterial({ side: three.DoubleSide });
      for (const info of meshes) {
        const mesh = new three.Mesh(geometries[info.geometry], material);
        mesh.name = info.geometry;
        mesh.position.fromArray(info.position);
        group.add(mesh);
      }
      scene.updateMatrixWorld(true);
      const camera = projection === 'perspective'
        ? new three.PerspectiveCamera(50, 1.4, .1, 100)
        : new three.OrthographicCamera(-7, 7, 5, -5, .1, 100);
      camera.position.fromArray(origin).add(new three.Vector3(4, 3, 10));
      camera.lookAt(new three.Vector3(...origin));
      camera.updateMatrixWorld(true);
      const rays = [];
      for (const x of [-.73, -.31, .03, .29, .67]) {
        for (const y of [-.69, -.27, .07, .33, .71]) {
          const cast = new three.Raycaster();
          cast.setFromCamera(new three.Vector2(x, y), camera);
          rays.push({
            origin: cast.ray.origin.toArray(), direction: cast.ray.direction.toArray(),
            hits: cast.intersectObject(scene, true).map(hit => ({
              name: hit.object.name, distance: hit.distance, point: hit.point.toArray(),
              triangle: hit.faceIndex, uv: hit.uv.toArray(),
              normal: hit.face.normal.clone().applyNormalMatrix(
                new three.Matrix3().getNormalMatrix(hit.object.matrixWorld),
              ).toArray(),
            })),
          });
        }
      }
      cases.push({origin, scale, projection, position: group.position.toArray(),
        quaternion: group.quaternion.toArray(), rays});
    }
  }
}
const sourceRoot = path.join(path.dirname(require.resolve('three')), '..');
const hashes = Object.fromEntries(['src/core/Raycaster.js', 'src/math/Ray.js', 'src/objects/Mesh.js'].map(file => [
  file, crypto.createHash('sha256').update(fs.readFileSync(path.join(sourceRoot, file))).digest('hex'),
]));
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify({three: '0.184.0', hashes, geometries: geometryData, meshes, cases}, null, 2) + '\n');
console.log(`${cases.length} scenes, ${cases.reduce((n, c) => n + c.rays.length, 0)} rays, ${cases.reduce((n, c) => n + c.rays.reduce((m, r) => m + r.hits.length, 0), 0)} hits`);
