#!/usr/bin/env python3
"""Compile Android XR GLSL and regenerate the checked-in SPIR-V header."""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('glslc', help='NDK shader-tools/<host>/glslc')
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
source = Path(__file__).resolve().parent.parent / 'src/main/cpp'
output = '#pragma once\n#include <cstdint>\n'
with tempfile.TemporaryDirectory(prefix='zyren-xr-shaders-') as folder:
    for filename, name in [('camera.vert', 'vert'), ('camera.frag', 'frag'), ('depth.comp', 'depth')]:
        binary = Path(folder) / (filename + '.spv')
        subprocess.run([args.glslc, str(source / filename), '-o', str(binary)], check=True)
        words = ','.join(hex(word[0]) for word in struct.iter_unpack('<I', binary.read_bytes()))
        output += f'static const uint32_t {name}Shader[] = {{{words}}};\n'
header = source / 'shaders.h'
if args.check:
    if header.read_text() != output:
        raise SystemExit('The Android XR shader header does not match its GLSL sources.')
else:
    header.write_text(output)
