import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const [referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/orbit_reference.mjs REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const three = require('three');
const { OrbitControls } = require('three-stdlib');
const stdlibRoot = path.resolve(referenceRoot, 'node_modules/three-stdlib');
const stdlib = JSON.parse(fs.readFileSync(path.join(stdlibRoot, 'package.json')));
if (three.REVISION !== '184' || stdlib.version !== '2.36.1') throw new Error('Unexpected reference versions');

class Surface {
  listeners = new Map();
  style = {};
  clientWidth = 800;
  clientHeight = 600;
  ownerDocument = this;
  addEventListener(name, callback) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(callback);
  }
  removeEventListener(name, callback) { this.listeners.get(name)?.delete(callback); }
  emit(name, data) {
    for (const callback of this.listeners.get(name) ?? []) callback({
      preventDefault() {}, ctrlKey: false, metaKey: false, shiftKey: false,
      pointerId: 1, pointerType: 'mouse', button: 0, ...data,
    });
  }
  getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth, height: this.clientHeight }; }
  releasePointerCapture() {}
}

const pointer = (type, x, y, extra = {}) => ({ type, x, y, ...extra });
const actions = [
  pointer('down', 300, 250), pointer('move', 360, 280), pointer('move', 390, 230),
  { type: 'up' }, { type: 'tick', count: 5 },
  pointer('down', 200, 200, { button: 2 }), pointer('move', 240, 180), { type: 'up' },
  pointer('down', 300, 200, { shift: true }), pointer('move', 280, 240), { type: 'cancel' },
  pointer('wheel', 580, 210, { dy: -3 }), pointer('wheel', 580, 210, { dy: 240 }),
  pointer('down', 400, 300, { button: 1 }), pointer('move', 400, 350), pointer('move', 400, 330), { type: 'up' },
  { type: 'key', code: 'ArrowLeft' }, { type: 'key', code: 'ArrowUp', shift: true },
  { type: 'save' }, { type: 'resize', width: 360, height: 640 },
  pointer('down', 100, 100, { touch: true, id: 1 }),
  pointer('wheel', 180, 100, { dy: 50 }),
  pointer('move', 120, 130, { touch: true, id: 1 }), { type: 'up', touch: true, id: 1 },
  pointer('down', 100, 200, { touch: true, id: 1 }),
  pointer('down', 220, 200, { touch: true, id: 2 }),
  pointer('move', 70, 230, { touch: true, id: 1 }),
  pointer('move', 250, 260, { touch: true, id: 2 }),
  { type: 'up', touch: true, id: 2 }, pointer('move', 50, 280, { touch: true, id: 1 }),
  { type: 'cancel', touch: true, id: 1 }, { type: 'tick', count: 20 }, { type: 'reset' },
  { type: 'polar', value: 1.1 }, { type: 'azimuth', value: 6.1 },
  { type: 'in', factor: .8 }, { type: 'out', factor: .8 },
  { type: 'scale', value: 1.3 },
];
const variants = [
  { name: 'default', options: {} },
  { name: 'damped', options: { enableDamping: true } },
  { name: 'cursor', options: { zoomToCursor: true } },
  { name: 'cursor-damped', options: { zoomToCursor: true, enableDamping: true } },
  { name: 'ground', options: { zoomToCursor: true, screenSpacePanning: false } },
  { name: 'limits', options: { minDistance: 10, maxDistance: 13, minZoom: .9, maxZoom: 1.1, minPolarAngle: .4, maxPolarAngle: 1.3, minAzimuthAngle: -.3, maxAzimuthAngle: .5 } },
  { name: 'reverse', options: { reverseOrbit: true, rotateSpeed: .7, panSpeed: 1.2, zoomSpeed: 1.5 } },
  { name: 'map', options: { screenSpacePanning: false }, map: true },
  { name: 'earth', options: { zoomToCursor: true, enableDamping: true }, origin: [6378137, 100, 3000] },
  ...[30, 60, 120].map(fps => ({ name: `auto-${fps}`, options: { autoRotate: true }, fps })),
];
const rows = [];
for (const kind of ['perspective', 'orthographic']) {
  for (const up of [[0, 1, 0], [0, 0, 1]]) {
    for (const variant of variants) {
      const surface = new Surface();
      const camera = kind === 'perspective'
        ? new three.PerspectiveCamera(50, 800 / 600, 1, 10000)
        : new three.OrthographicCamera(-8, 8, 6, -6, 0, 10000);
      const origin = variant.origin ?? [0, 0, 0];
      camera.position.set(origin[0] + 4, origin[1] + 6, origin[2] + 10);
      camera.up.fromArray(up);
      const controls = new OrbitControls(camera, surface);
      controls.target.fromArray(origin);
      Object.assign(controls, variant.options);
      if (variant.map) {
        controls.mouseButtons.LEFT = three.MOUSE.PAN;
        controls.mouseButtons.RIGHT = three.MOUSE.ROTATE;
        controls.touches.ONE = three.TOUCH.PAN;
        controls.touches.TWO = three.TOUCH.DOLLY_ROTATE;
      }
      controls.listenToKeyEvents(surface);
      controls.update();
      if (variant.origin) controls.saveState();
      const events = [];
      for (const name of ['start', 'change', 'end']) controls.addEventListener(name, () => events.push(name));
      const trace = [];
      function capture(action) {
        camera.updateMatrixWorld();
        trace.push({ action, position: camera.position.toArray(), target: controls.target.toArray(),
          quaternion: camera.quaternion.toArray(), zoom: camera.zoom, events: events.splice(0) });
      }
      for (const action of variant.fps ? [{ type: 'tick', count: variant.fps }] : actions) {
        const event = { clientX: action.x ?? 0, clientY: action.y ?? 0,
          pageX: action.x ?? 0, pageY: action.y ?? 0, pointerId: action.id ?? 1,
          pointerType: action.touch ? 'touch' : 'mouse', button: action.button ?? 0,
          deltaY: action.dy, code: action.code, shiftKey: action.shift ?? false };
        switch (action.type) {
          case 'down': surface.emit('pointerdown', event); break;
          case 'move': surface.emit('pointermove', event); break;
          case 'up': surface.emit('pointerup', event); break;
          case 'cancel': surface.emit('pointercancel', event); break;
          case 'wheel': surface.emit('wheel', event); break;
          case 'key': surface.emit('keydown', event); break;
          case 'save': controls.saveState(); break;
          case 'reset': controls.reset(); break;
          case 'polar': controls.setPolarAngle(action.value); break;
          case 'azimuth': controls.setAzimuthalAngle(action.value); break;
          case 'in': controls.dollyIn(action.factor); break;
          case 'out': controls.dollyOut(action.factor); break;
          case 'scale': controls.setScale(action.value); break;
          case 'resize':
            surface.clientWidth = action.width; surface.clientHeight = action.height;
            if (kind === 'perspective') camera.aspect = action.width / action.height;
            camera.updateProjectionMatrix(); break;
          case 'tick':
            for (let i = 0; i < action.count; i++) {
              controls.update(); capture({ type: 'tick' });
            }
            continue;
        }
        capture(action);
      }
      rows.push({ kind, up, ...variant, trace });
      controls.dispose();
    }
  }
}
const source = fs.readFileSync(path.join(stdlibRoot, 'controls/OrbitControls.cjs'));
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify({ three: '0.184.0', stdlib: stdlib.version,
  sourceSha256: crypto.createHash('sha256').update(source).digest('hex'), rows }) + '\n');
console.log(`${rows.length} traces, ${rows.reduce((n, row) => n + row.trace.length, 0)} steps`);
