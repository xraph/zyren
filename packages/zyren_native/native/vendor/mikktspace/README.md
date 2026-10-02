# MikkTSpace

These files come from Morten S. Mikkelsen's reference implementation at
[3e895b49d05ea07e4c2133156cfa94369e19e409](https://github.com/mmikk/MikkTSpace/tree/3e895b49d05ea07e4c2133156cfa94369e19e409).
The original license is preserved at the top of each source file.

`mikktspace.h` has trailing whitespace removed. `mikktspace.c` is an altered
version, with the same whitespace cleanup and these functional changes:

- Every active `for` and `while` condition charges the adapter's iteration budget.
- Four recursive functions use wrappers that check a shared depth limit.
- Assertions use the adapter's error return path instead of terminating the app.
- Sort-pivot seed rotations mask the shift count, avoiding a shift by 32.
- Zero-extent position bounds select hash cell zero, avoiding a NaN-to-int cast.

Tangent calculations are unchanged. `src/tangents.c` supplies the hooks, tracks
scratch allocations and releases them on success or failure. Its `setjmp` and
`longjmp` calls stay inside C frames. No Rust or Dart callback is crossed.

When you update this dependency, compare every local change against the new
reference source and regenerate the reference fixture with an unmodified copy.
