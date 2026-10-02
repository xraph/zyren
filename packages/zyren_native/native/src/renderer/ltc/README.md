# LTC table provenance

These two files contain the 64 × 64 × 4 float32 tables from
[Three.js r180 RectAreaLightTexturesLib.js](https://github.com/mrdoob/three.js/blob/r180/examples/jsm/lights/RectAreaLightTexturesLib.js).
The upstream source attributes its fitted data to
[selfshadow/ltc_code](https://github.com/selfshadow/ltc_code/tree/master/fit/results).
The LTC authors' license is retained beside these files. Three.js MIT terms are
in the repository's third-party notices.

We extracted `LTC_MAT_1` and `LTC_MAT_2` and encoded each number as a little-endian
IEEE float32, preserving array order. The renderer reads texels without changing
the layout.

SHA-256:

- Source: `8acc50043aebc3ff0f63e21607ef2394cda41d634f92093bcb7ad6f1d1e2eb11`
- `ltc_1.bin`: `cf5cf21e5c112d2095c7e2418cb0a1ac54636e275d73e42f3453646c67f26814`
- `ltc_2.bin`: `3b1b09080b26104498db277c14fc1733786465c6958e7a8403d688b1e24c2ff5`
