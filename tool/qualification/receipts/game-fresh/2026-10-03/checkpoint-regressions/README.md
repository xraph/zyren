# Checkpoint and foreground control regressions

The isolated checkout passed 108 tests covering Studio input/lifecycle,
authored checkpoint selection and respawn, native controls/saves, physics state
freshness, and AI runtime/topology. This includes 144 learned actors sharing one
model while retaining separate recurrent state.

The foreground test first reproduced a real failure: holding forward after
resume left the character at its starting position. The repaired native runtime
reacquires possession when the core session resumes. The final suite verifies
movement after that transition.

The source overlay manifest pins the checked files against the detached base.
Logs retain the initial failure and final passing checks. These results include
the immutable physics snapshot cache and immediate game cohort dispatch. They
predate the separate native collision-query cache and do not qualify physical
presentation, accessibility or sustained capacity.
