import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const [referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/camera_reference.mjs REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const three = require('three');
if (three.REVISION !== '184') throw new Error('Expected Three r184');
const rows = [];
function sampleCamera(kind, position, zoom, aspect) {
  const camera = kind === 'perspective'
    ? new three.PerspectiveCamera(50, aspect, 1, 1e5)
    : new three.OrthographicCamera(-3, 5, 4, -2, 0, 1e5);
  camera.position.fromArray(position);
  const target = new three.Vector3(position[0] + 1, position[1] - 2, position[2] - 10);
  camera.up.set(0, 1, .2);
  camera.lookAt(target);
  camera.zoom = zoom;
  camera.updateProjectionMatrix();
  camera.updateMatrixWorld();
  // Native snapshots subtract the camera origin before the view transform.
  const relativeView = camera.matrixWorldInverse.clone();
  relativeView.setPosition(0, 0, 0);
  const vp = camera.projectionMatrix.clone().multiply(relativeView);
  const depth = new three.Matrix4().set(
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, .5, .5,
    0, 0, 0, 1,
  );
  vp.premultiply(depth);
  const samples = [[0, 0], [-.9, .8], [.7, -.6]].map(xy => {
    const ray = new three.Raycaster();
    ray.setFromCamera(new three.Vector2(...xy), camera);
    const point = target.clone().add(new three.Vector3(xy[0], xy[1], 0));
    const projected = point.clone().project(camera);
    projected.z = (projected.z + 1) / 2;
    return {
      xy, origin: ray.ray.origin.toArray(), direction: ray.ray.direction.toArray(),
      point: point.toArray(), projected: projected.toArray(),
    };
  });
  return {
    kind, position, target: target.toArray(), up: camera.up.toArray(),
    zoom, aspect, matrix: vp.toArray(), samples,
  };
}
for (const kind of ['perspective', 'orthographic']) {
  for (const position of [[0, 0, 5], [6378137, 100, 3000]]) {
    for (const zoom of [.5, 1, 3]) {
      for (const aspect of [.5, 1, 2]) {
        rows.push(sampleCamera(kind, position, zoom, aspect));
      }
    }
  }
}
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify({ three: '0.184.0', rows }, null, 2) + '\n');
console.log(`${rows.length} camera configurations`);
