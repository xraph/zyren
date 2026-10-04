# Native visual v2 feasibility

The first guard-combined course failed. No model was trained or accepted.

You can inspect `initial-course-failed.json` for the first 600-step result and `corrected-course-failed.json` for the route-preservation correction. Both retain their original observations and controller pins. `corrected-course-diagnostic.json` adds early accepted native controls and published route points; it shows continuous requested motion while the capsule's XZ position stays fixed for hundreds of ticks.

The corrected run used the repaired physics library SHA256 `8fda6c085dfe66c98a2cfcf5db6301181fec3d965bc14ef527595a5844acc17b`. Its source inventory is in `corrected-course-context.json`. It completed 121 real A6 captures, admitted a goal for 599 ticks and reported zero contacts, but did not reach the target. These counts do not establish useful control.

Shared contracts are committed in `00ec53b1dc7f2271a282fb3ebf8b2b4ddc8d60ab`. Sixteen contract tests, nine navigation tests, a 20-step native paired-hidden history and two mounted capture/class-ablation/drain tests passed. The worker adapter was still uncommitted at this receipt boundary. No v2 executable had been frozen.

The root engine investigation subsequently isolated an early capsule drop on a flat floor and a suspicious ground-snap hit. Its correction and the course rerun remain pending. All six family/mode quality obligations and the original success, safety, leakage and native parity gates remain open. Existing v1 plans and failed pilots are unchanged.
