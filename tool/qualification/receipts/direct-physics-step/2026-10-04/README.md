# Direct physics presentation

When you disable interpolation and admit a full step, the physics plugin uses
the body states returned by that step. It does not fetch all states beforehand.
Fractional updates still fetch current states, so external teleports appear
without waiting for another step. Interpolated presentation keeps its pre-read.

The focused run passed 19 physics tests and 37 game integration tests. Coverage
includes fractional teleports, before-step writes, multiple catch-up steps,
closed-world callback rejection, characters, vehicles, saves and clock lifecycle.
Scoped Dart analysis and independent source review passed.

These checks use native physics. Test renderers do not establish physical
presentation performance, and no sustained capacity result is claimed.
