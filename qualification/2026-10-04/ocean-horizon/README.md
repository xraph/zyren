# Atmospheric reflection at the water horizon

Compare `before.png` and `after.png` at the same storm timestamp, 1/60 second.
Both use the saved revision 2 source, the custom detailed profile and a 640x400
native Metal readback on the M3 Max.

The dark strips were water fragments. A facing diagnostic found front-facing
geometry across them, and an environment-only preview retained the strips with
SSR disabled. The reflected-light diagnostic reproduced them. Reflections below
the mean water horizon sampled the atmosphere's dark ground hemisphere.

The atmosphere adapter now uses grazing sky radiance for those unresolved water
reflections. SSR still replaces that fallback where it finds scene geometry.
This approximation does not trace multiple reflections between waves. Authored
HDR environments keep their original sampling.

In the fixed daylight image region x=0..639, y=150..299, the count of pixels with
all RGB channels below 20 fell from 87 to zero. The native regression permits
fewer than ten for device rounding. This check detects the original strips; it
does not establish professional art acceptance.

Validation: the saved-scene regression and four native atmosphere/environment,
SSR and Snell-window checks pass. Native resource allocations return to zero.
