"""Audited current-engine revision preserves the exact structured held-out suite."""
import hashlib
from pathlib import Path

import pytest

from zyren_train.evaluate import EvaluationPlan
from zyren_train.scenario import canonical_bytes

ROOT = Path(__file__).resolve().parents[3]
PREVIOUS = "deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd"
REASON = "collision-only island and joint bookkeeping repair"


def revision():
    value = EvaluationPlan.load(ROOT / "tool/zyren_train/qualification/2026-10-03/revised-plan.json").data
    value["id"] = "game-lab-held-out-v1-collision-repair-test"
    value["worker_sha256"] = "a" * 64
    value["worker_native_sha256"]["lib/libzyren_physics.dylib"] = "b" * 64
    value["revision"].update(supersedes=PREVIOUS, reason=REASON)
    return value


def repin_content(value):
    content = {key: value[key] for key in ("cases", "paired_worlds", "targets", "training_scenario_hashes")}
    value["revision"]["case_content_hash"] = hashlib.sha256(canonical_bytes(content)).hexdigest()


def test_collision_repair_admits_only_exact_old_content_and_lineage():
    value = revision()
    admitted = EvaluationPlan.from_dict(value)
    original = EvaluationPlan.load(ROOT / "tool/zyren_train/qualification/2026-10-03/revised-plan.json")
    assert admitted.requested == original.requested == 400
    for key in ("cases", "paired_worlds", "targets", "training_scenario_hashes"):
        assert canonical_bytes(admitted.data[key]) == canonical_bytes(original.data[key])
    assert admitted.hash != original.hash


@pytest.mark.parametrize("changed", ["seed", "pair", "training", "gate", "lineage", "reason"])
def test_collision_repair_rejects_mutated_content_even_when_rehashed(changed):
    value = revision()
    if changed == "seed": value["cases"][0]["seeds"][0] += 1
    elif changed == "pair": value["paired_worlds"]["seed"] += 1
    elif changed == "training": value["training_scenario_hashes"].append("c" * 64)
    elif changed == "gate": value["targets"]["guard"]["success_rate"] = .89
    elif changed == "lineage": value["revision"]["supersedes"] = "d" * 64
    elif changed == "reason": value["revision"]["reason"] = "new physics"
    repin_content(value)
    with pytest.raises(ValueError): EvaluationPlan.from_dict(value)


def test_original_audited_revision_bytes_remain_accepted():
    path = ROOT / "tool/zyren_train/qualification/2026-10-03/revised-plan.json"
    assert EvaluationPlan.load(path).hash == PREVIOUS
