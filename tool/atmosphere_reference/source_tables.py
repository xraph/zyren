#!/usr/bin/env python3
"""Evaluate the pinned upstream runtime against its actual half-float assets."""
from pathlib import Path
import argparse, hashlib, json, os, re, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('assets', type=Path)
parser.add_argument('--source', type=Path, default=Path('/Users/rexraphael/Work/TwinOS/three-geospatial-main'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
folder = Path(__file__).parent
shader = args.source / 'packages/atmosphere/src/shaders/bruneton'
inventory = json.loads((root / 'tool/reference/inventory.json').read_text())
asset_hashes = {}
for name in ['transmittance', 'irradiance', 'scattering', 'single_mie_scattering', 'higher_order_scattering']:
    data = (args.assets / (name + '.bin')).read_bytes()
    pointer = (args.source / 'packages/atmosphere/assets' / (name + '.bin')).read_text()
    digest = hashlib.sha256(data).hexdigest()
    assert f'oid sha256:{digest}' in pointer and f'size {len(data)}' in pointer
    asset_hashes[name] = digest
sizes = dict(TRANSMITTANCE_TEXTURE_WIDTH=256, TRANSMITTANCE_TEXTURE_HEIGHT=64,
    SCATTERING_TEXTURE_R_SIZE=32, SCATTERING_TEXTURE_MU_SIZE=128,
    SCATTERING_TEXTURE_MU_S_SIZE=32, SCATTERING_TEXTURE_NU_SIZE=8,
    IRRADIANCE_TEXTURE_WIDTH=64, IRRADIANCE_TEXTURE_HEIGHT=16)
base = ''.join(f'#define {key} {value}\n' for key, value in sizes.items())
base += (folder / 'compat.hpp').read_text()
hashes = {}
for name in ['common.glsl', 'runtime.glsl']:
    code = (shader / name).read_text()
    hashes[name] = hashlib.sha256(code.encode()).hexdigest()
    blob = hashlib.sha1(f'blob {len(code.encode())}\0'.encode() + code.encode()).hexdigest()
    assert next(f['gitBlob'] for f in inventory['files'] if f['path'] == f'packages/atmosphere/src/shaders/bruneton/{name}') == blob
    code = re.sub(r'\b(?:out|inout) (\w+) (\w+)', r'\1& \2', code)
    code = code.replace('DensityProfileLayer layers[2] = profile.layers;', 'const auto& layers = profile.layers;')
    if name == 'runtime.glsl':
        code = code.split('Luminance3 GetSolarLuminance()', 1)[0]
        # Mechanical vector spelling changes for the C++ host.
        code = code.replace('scattering.rgb', 'vec3(scattering)')
        code = re.sub(r'\.r\b', '.x', code)
        code = re.sub(r'\.a\b', '.w', code)
    base += code
base += (folder / 'source_driver.cpp').read_text()
with tempfile.TemporaryDirectory(prefix='zyren-source-atmosphere-') as directory:
    path = Path(directory)
    for packed in [True, False]:
        mode = 'packed' if packed else 'full'
        (path / 'main.cpp').write_text(('#define COMBINED_SCATTERING_TEXTURES\n' if packed else '') + base)
        subprocess.run(['clang++', '-O2', '-std=c++17', str(path/'main.cpp'), '-o', str(path/'run')], check=True)
        result = json.loads(subprocess.check_output([str(path/'run')], env={**os.environ, 'SOURCE_LUTS': str(args.assets.resolve())}, text=True))
        result['source'] = dict(shaderSha256=hashes, assetSha256=asset_hashes,
            assetCommit='eac103980f20c0956f2d3215833e73514be08462', sizes=sizes,
            precision='CPU double; original GLSL runtime; source half-float tables', packed=packed)
        output = root / f'packages/zyren_geospatial/test/fixtures/atmosphere/scattering-source-{mode}.json'
        output.write_text(json.dumps(result, indent=2) + '\n')
        print(output)
