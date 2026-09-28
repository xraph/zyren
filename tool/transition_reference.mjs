import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/transition_reference.mjs REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const three = require('three');
const root = path.resolve(referenceRoot, 'node_modules/3d-tiles-renderer');
if (three.REVISION !== '184' || JSON.parse(fs.readFileSync(path.join(root, 'package.json'))).version !== '0.4.24') {
  throw new Error('Expected Three r184 and 3d-tiles-renderer 0.4.24');
}
const { CameraTransitionManager } = await import(pathToFileURL(path.join(root, 'src/three/renderer/controls/CameraTransitionManager.js')));
const cases = [];
for (const hz of [30, 60, 120]) {
  for (const positionalZoom of [true, false]) {
    for (const rotated of [false, true]) {
      const initial = {
        position: rotated ? [130, 240, 310] : [0, 0, 100],
        target: rotated ? [20, -15, 8] : [0, 0, 0],
        up: rotated ? [0, 0, 1] : [0, 1, 0],
        fixed: rotated ? [30, -10, 15] : [2, 3, 0],
      };
      const perspective = new three.PerspectiveCamera(50, 1.5, .1, 100000);
      perspective.position.fromArray(initial.position);
      perspective.up.fromArray(initial.up);
      perspective.lookAt(new three.Vector3(...initial.target));
      perspective.updateMatrixWorld();
      const orthographic = new three.OrthographicCamera(-3, 3, 2, -2, .5, 200000);
      orthographic.position.set(0, 0, 1000);
      const manager = new CameraTransitionManager(perspective, orthographic);
      manager.fixedPoint.fromArray(initial.fixed);
      manager.orthographicPositionalZoom = positionalZoom;
      const events = [];
      for (const name of ['toggle', 'change', 'transition-start', 'camera-change', 'transition-end']) {
        manager.addEventListener(name, () => events.push(name));
      }
      const steps = [];
      function sample(action, dt = 0) {
        events.length = 0;
        if (action === 'toggle') manager.toggle();
        else manager.update(dt);
        const c = manager.camera;
        steps.push({ action, dt, alpha: manager.alpha, animating: manager.animating,
          kind: c === perspective ? 'perspective' : c === orthographic ? 'orthographic' : 'transition',
          position: c.position.toArray(), forward: new three.Vector3(0, 0, -1).applyQuaternion(c.quaternion).toArray(),
          up: new three.Vector3(0, 1, 0).applyQuaternion(c.quaternion).toArray(),
          fov: c.isPerspectiveCamera ? c.fov * Math.PI / 180 : null,
          zoom: c.zoom, near: c.near, far: c.far, events: [...events] });
      }
      sample('update');
      sample('toggle');
      for (let i = 0; i < Math.ceil(hz * .22); i++) sample('update', 1 / hz);
      sample('toggle');
      for (let i = 0; i < Math.ceil(hz * .22); i++) sample('update', 1 / hz);
      sample('toggle');
      sample('update', .08);
      sample('toggle');
      sample('update', .04);
      sample('update', .2);
      cases.push({ hz, positionalZoom, initial, steps });
    }
  }
}
fs.writeFileSync(output, JSON.stringify({ source: '3d-tiles-renderer 0.4.24', three: three.REVISION, cases }, null, 2) + '\n');
