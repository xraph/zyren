"""Convert the documented NOAA Monterey subsets into pinned scalar grids.

Usage: python3 tool/import_etopo.py relief.csv geoid.nc assets/ocean/monterey
Requires the NetCDF ncdump command. No network access is performed.
"""

import csv
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import sys


def main(relief_path, geoid_path, output_path):
    relief = Path(relief_path)
    geoid = Path(geoid_path)
    output = Path(output_path)
    rows = list(csv.reader(relief.read_text().splitlines()))
    if rows[:2] != [["latitude", "longitude", "z"],
                    ["degrees_north", "degrees_east", ""]]:
        raise ValueError("Unexpected ERDDAP columns or units")
    samples = [tuple(map(float, row)) for row in rows[2:]]
    lats = sorted({row[0] for row in samples})
    lons = sorted({row[1] for row in samples})
    if not 4 <= len(samples) == len(lats) * len(lons) <= 262144:
        raise ValueError("Expected a complete bounded regular grid")
    heights = {(lat, lon): h for lat, lon, h in samples}
    if len(heights) != len(samples):
        raise ValueError("Duplicate relief cell")
    cdl = subprocess.check_output(
        ["ncdump", "-p", "9,17", "-v", "lat,lon,z", str(geoid)], text=True)
    data = cdl.split("data:", 1)[1]

    def values(name):
        block = re.search(r"\b" + name + r"\s*=\s*(.*?);", data, re.S)[1]
        return [float(v.strip()) for v in block.split(",")]

    for expected, actual in [(lats, values("lat")), (lons, values("lon"))]:
        if len(expected) != len(actual) or any(
                abs(a - b) > 1e-9 for a, b in zip(expected, actual)):
            raise ValueError("Geoid and relief coordinates differ")
        if any(abs((actual[i] - actual[i - 1]) - 1 / 240) > 1e-9
               for i in range(1, len(actual))):
            raise ValueError("Expected native 15 arc-second sampling")
    n = values("z")
    h = [heights[lat, lon] for lat in lats for lon in lons]
    if len(n) != len(h) or any(not math.isfinite(v) or abs(v) > 12000
                              for v in h + n):
        raise ValueError("Missing or invalid height cell")
    fields = {"height": [a + b for a, b in zip(h, n)],
              "depth": [max(0, -v) for v in h],
              "water": [float(v < 0) for v in h], "geoid": n}
    bounds = [math.radians(v) for v in [lons[0], lats[0], lons[-1], lats[-1]]]
    output.mkdir(parents=True, exist_ok=True)
    resources = {}
    for name, grid in fields.items():
        encoded = struct.pack("<4I4d", 0x3146475A, len(lons), len(lats), 0, *bounds)
        encoded += struct.pack(f"<{len(grid)}d", *grid)
        (output / f"{name}.zgrid").write_bytes(encoded)
        resources[name] = {"bytes": len(encoded),
                           "sha256": hashlib.sha256(encoded).hexdigest()}
    manifest = {
        "version": 1, "revision": "noaa-etopo2022-monterey-1",
        "boundsRadians": bounds, "width": len(lons), "height": len(lats),
        "sourceDatum": "EGM2008", "terrainDatum": "WGS84 ellipsoid",
        "seaLevelEllipsoidMetres": n[(len(lats) // 2) * len(lons) + len(lons) // 2],
        "geoidRangeMetres": [min(n), max(n)],
        "sourceFilesSha256": {
            "relief.csv": hashlib.sha256(relief.read_bytes()).hexdigest(),
            "geoid.nc": hashlib.sha256(geoid.read_bytes()).hexdigest()},
        "resources": resources,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Imported {len(lons)} x {len(lats)} cells; geoid {min(n):.3f}..{max(n):.3f} m")


if __name__ == "__main__":
    main(*sys.argv[1:])
