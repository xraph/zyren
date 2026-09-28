import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
const [referenceRoot, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tool/environment_reference.mjs REFERENCE OUTPUT');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const three = require('three');
const root = path.resolve(referenceRoot, 'node_modules/3d-tiles-renderer');
if (three.REVISION !== '184' || JSON.parse(fs.readFileSync(path.join(root, 'package.json'))).version !== '0.4.24') throw new Error('Reference version mismatch');
const { EnvironmentControls } = await import(pathToFileURL(path.join(root, 'src/three/renderer/controls/EnvironmentControls.js')));
globalThis.window = { devicePixelRatio: 2 };
class Surface {
  style = {}; clientWidth = 800; clientHeight = 600; listeners = new Map();
  addEventListener(n, cb) { if (!this.listeners.has(n)) this.listeners.set(n, new Set()); this.listeners.get(n).add(cb); }
  removeEventListener(n, cb) { this.listeners.get(n)?.delete(cb); }
  getRootNode() { return this; }
  getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth, height: this.clientHeight }; }
  setPointerCapture() {} releasePointerCapture() {}
  emit(n, event) { for (const cb of this.listeners.get(n) ?? []) cb({ type: n, preventDefault() {}, ...event }); }
}
const p = (type, x, y, extra = {}) => ({ type, x, y, ...extra });
const actions = [
  p('down', 300, 260), p('move', 340, 290), p('move', 370, 310), { type: 'up' },
  { type: 'tick', count: 15 },
  p('down', 500, 350, { buttons: 2 }), p('move', 540, 380), { type: 'up' },
  { type: 'tick', count: 15 },
  p('down', 320, 280, { shift: true }), p('move', 290, 240), { type: 'cancel' },
  p('wheel', 470, 300, { dy: -120 }), p('wheel', 470, 300, { dy: 2, mode: 1 }),
  p('hover', 200, 220), p('wheel', 200, 220, { dy: -.1, mode: 2 }),
  p('down', 320, 300, { buttons: 4 }), p('move', 370, 320), { type: 'up' },
  p('down', 320, 300, { ctrl: true }), p('move', 330, 305), { type: 'up' },
  { type: 'resize', width: 390, height: 700 },
  p('down', 100, 300, { touch: true }), p('move', 110, 320, { touch: true }), { type: 'up' },
  p('down', 100, 300, { touch: true }), p('down', 260, 300, { touch: true, id: 2 }),
  { type: 'batch', points: [p('move', 70, 300, { touch: true }), p('move', 290, 300, { touch: true, id: 2 })] },
  { type: 'batch', points: [p('move', 60, 310, { touch: true }), p('move', 300, 310, { touch: true, id: 2 })] },
  { type: 'up' },
  p('down', 100, 300, { touch: true }), p('down', 260, 300, { touch: true, id: 2 }),
  { type: 'batch', points: [p('move', 110, 320, { touch: true }), p('move', 270, 320, { touch: true, id: 2 })] },
  { type: 'cancel' }, { type: 'tick', count: 15 },
  p('down', 100, 300, { touch: true }), p('down', 260, 300, { touch: true, id: 2 }),
  p('down', 160, 200, { touch: true, id: 3 }), { type: 'up' },
];
const cases = [];
for (const hz of [30, 60, 120]) for (const damping of [false, true]) for (const kind of ['perspective', 'orthographic']) for (const zUp of [false, true]) {
  const surface = new Surface();
  const camera = kind === 'perspective' ? new three.PerspectiveCamera(50, 800/600, .1, 100000) : new three.OrthographicCamera(-80, 80, 60, -60, 0, 100000);
  const initial = { position: zUp ? [40, -100, 60] : [40, 60, 100], up: zUp ? [0, 0, 1] : [0, 1, 0] };
  camera.position.fromArray(initial.position); camera.up.fromArray(initial.up); camera.lookAt(0,0,0); camera.updateMatrixWorld();
  const controls = new EnvironmentControls(new three.Scene(), camera, surface);
  controls.up.fromArray(initial.up); controls.fallbackPlane.normal.fromArray(initial.up); controls.enableDamping = damping;
  controls.update(1/hz);
  const events = []; for (const n of ['start','change','end']) controls.addEventListener(n, () => events.push(n));
  const trace = [];
  function capture(action) {
    trace.push({ action, position: camera.position.toArray(), forward: new three.Vector3(0,0,-1).applyQuaternion(camera.quaternion).toArray(), up: new three.Vector3(0,1,0).applyQuaternion(camera.quaternion).toArray(), zoom: camera.zoom, pivot: controls.pivotPoint.toArray(), state: controls.state, events: events.splice(0) });
  }
  function emit(a) { surface.emit(({ down:'pointerdown',move:'pointermove',hover:'pointermove',up:'pointerup',wheel:'wheel' })[a.type], { clientX:a.x??0,clientY:a.y??0,pointerId:a.id??1,pointerType:a.touch?'touch':'mouse',buttons:a.buttons??1,shiftKey:a.shift??false,ctrlKey:a.ctrl??false,deltaY:a.dy??0,deltaMode:a.mode??0 }); }
  for (const action of actions) {
    if (action.type === 'tick') { for (let i=0;i<action.count;i++) { controls.update(1/hz); capture({type:'tick'}); } continue; }
    if (action.type === 'cancel') controls.resetState();
    else if (action.type === 'resize') { surface.clientWidth=action.width; surface.clientHeight=action.height; if (kind==='perspective') camera.aspect=action.width/action.height; camera.updateProjectionMatrix(); }
    else if (action.type === 'batch') action.points.forEach(emit);
    else emit(action);
    await Promise.resolve(); controls.update(1/hz); capture(action);
  }
  cases.push({hz,damping,kind,initial,trace}); controls.dispose();
}
fs.writeFileSync(output, JSON.stringify({source:'3d-tiles-renderer 0.4.24',dpr:2,cases})+'\n');
