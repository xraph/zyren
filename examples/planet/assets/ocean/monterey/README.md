# Monterey Bay offline region

You can open Monterey Bay from the Ocean scene list without a network connection.
The bundled region contains 96x72 samples at NOAA's native 15 arc-second spacing.
These elevations describe regional relief. They cannot resolve individual rocks,
breakers or harbour structures.

Source: NOAA National Centers for Environmental Information (2022),
[ETOPO 2022 15 Arc-Second Global Relief Model](https://doi.org/10.25921/fd45-gt74),
accessed 4 October 2026. NOAA distributes this dataset under CC0-1.0. Its
[metadata and use constraints](https://www.ncei.noaa.gov/access/metadata/landing-page/bin/iso?id=gov.noaa.ngdc.mgg.dem:etopo_2022)
exclude navigation use. You can redistribute the region offline with its credit.

The relief subset comes from
[NOAA CoastWatch ERDDAP](https://coastwatch.pfeg.noaa.gov/erddap/griddap/ETOPO_2022_v1_15s.html).
The geoid subset comes from NOAA's
[ETOPO geoid tiles](https://www.ngdc.noaa.gov/thredds/catalog/global/ETOPO2022/15s/15s_geoid_netcdf/catalog.html),
file `ETOPO_2022_v1_15s_N45W135_geoid.nc`. The geoid file identifies its underlying
NGA data as public domain.

`manifest.json` pins the original file hashes and all four encoded resources.
`height.zgrid` contains ellipsoid height H+N, using the EGM2008 relief H and the
coincident geoid height N. `depth.zgrid` retains positive bathymetry below EGM2008,
`water.zgrid` marks negative relief, and `geoid.zgrid` retains N. No elevation
resampling or vertical exaggeration is applied. Grid bounds are sample centres.

The water simulation uses a constant regional ellipsoid level of -34.2269363 m.
The source geoid ranges from -35.8238907 to -33.2841148 m, so this water surface
can differ from the local geoid by up to 1.60 m. Tides are not included. Shore
foam uses depth derived from the rendered surface level and converted terrain.
Keep that approximation separate from numerical wave-query error bounds.

The region is published through a D3 manifest and FileGeoDataStore. Each import
checks the pinned SHA-256 digest. Rendering and water coverage queries consume
only verified offline resolver bytes; outside-region queries remain unavailable.

To reproduce the four grids from the preserved source files, install `ncdump`
and run from `examples/planet`:

```sh
python3 tool/import_etopo.py \
  ../../qualification/2026-10-04/ocean-monterey/source/relief.csv \
  ../../qualification/2026-10-04/ocean-monterey/source/geoid.nc \
  assets/ocean/monterey
```
