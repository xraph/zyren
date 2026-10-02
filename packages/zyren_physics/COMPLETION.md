# Physics implementation checks

You can use this table to distinguish implementation from native qualification.
The package uses actual Rapier simulation. Qualification never substitutes a mock
for the native library.

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Optional native asset and isolated scoped worlds | Implemented | macOS native Dart tests |
| All body modes, mass, forces, torque, sleep and reset | Implemented | macOS native Dart tests |
| Box, sphere, capsule, convex, mesh and compound | Implemented | macOS native Dart tests |
| Offsets, masks, materials, sensors and CCD | Implemented | Native coverage expanding |
| Fixed stepping, catch-up, interpolation and ownership | Implemented | Plugin lifecycle tests |
| Six joint types, limits and runtime motors | Implemented | Native coverage expanding |
| Ray, shape and overlap queries | Implemented | macOS native Dart tests |
| Collision, sensor and contact events | Implemented | Native events and cleanup tests |
| Snapshots and renderer recovery | Implemented | Native restore and reattach tests |
| Native debug geometry | Implemented | Geometry tests; rendered check open |
| Physics Lab app and package documentation | Implemented | macOS app build passed; live check open |
| macOS execution | Library verified | Seven native Dart tests and three Rust tests passed |
| iOS, Android, Linux and Windows build support | Target wiring implemented | Platform builds and hardware qualification open |

Current checks: package and example analysis, native Rust format, strict Clippy and
Rust tests. The first package milestone excludes shared native renderer changes
from other active chats. The example and platform qualification continue separately.
