# Celestial directions

`CelestialDirections.at(date, observerECEF: position)` returns unit sun/moon
vectors in J2000 equatorial ECI and Earth-fixed ECEF coordinates. The optional
observer is in ECEF metres. It adds topocentric parallax before normalization.
Distances remain geocentric, in metres. `eciToEcef` and `moonFixedToEci` are
immutable column-major matrices for star and lunar orientation.

The implementation ports the sun/moon subset of Astronomy Engine 2.1.19 used by
the supplied three-geospatial snapshot `b012ad06d858fc035d88aacfd73f092f93c994e4`.
It retains Earth VSOP coefficients, the Brown lunar series, precession, nutation,
Greenwich apparent sidereal time and lunar pole/spin equations. It runs entirely
in Dart and imports only the public Zyren API. It does not include the engine's
planet search, eclipse, constellation or orbital-simulation APIs.

`AstronomicalTime` converts an instant to UTC and keeps millisecond precision,
as the source JavaScript Date does. UT days start at J2000 noon. The source treats
UTC as UT and derives TT through the Espenak-Meeus Delta T polynomial. We preserve
that convention; no live UT1 or leap-second table is consulted. Equal instants
with different UTC offsets produce identical results. Dates outside years -9999
through 9999 and nonfinite or excessively distant observers fail explicitly.
Date admission is not a claim of observational accuracy across that whole span.

## Reference evidence

`tool/celestial_reference.mjs` executes the supplied `celestialDirections.ts`
against Three.js 0.184.0 and Astronomy Engine 2.1.19. It checks the source Git blob
and records the dependency version and Astronomy Engine source SHA-256.

The committed fixture has 55 celestial cases from 1600 to 2400: equinoxes,
solstices, a millisecond across UTC midnight, the equator, a polar observer,
a mid-latitude observer and a position above Earth. Another 31 cases span Delta T
polynomial branches and the accepted date endpoints.

The Dart comparison passes with maximum component errors of 2.84e-15 for unit
directions and 1.69e-12 for rotation matrices. The declared limits are 2e-10 for
those components, 1e-9 sidereal hours, 0.1 metre for sun distance and 0.001 metre
for moon distance. These measure agreement with the pinned library, not error
against an observational ephemeris. Calls are independent and have no mutable
global ephemeris cache.

The optional atmosphere plugin will consume these values. Passing these numerical
fixtures does not establish rendered sky, sun, moon or star parity.
