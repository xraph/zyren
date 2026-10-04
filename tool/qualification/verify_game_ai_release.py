#!/usr/bin/env python3
"""Check game/AI completion evidence and fail closed on unfinished requirements."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import math
import struct

ROOT = Path(__file__).resolve().parents[2]
STATUSES = {"passed", "failed", "blocked", "notApplicable"}
DIMENSIONS = ("implemented", "automated", "native", "trainedArtifact", "documentation")
REQUIREMENTS = {f"R{i:02}" for i in range(1, 33)}
TASKS = {f"{prefix}{i}" for prefix, count in (("G", 7), ("S", 7), ("A", 7), ("T", 6), ("Q", 5))
         for i in range(1, count + 1)}
TARGETS = {"macos-metal", "android-vulkan", "ios-metal", "windows-dx12", "linux-vulkan"}
# These requirements include physical input, execution, presentation or capacity.
NATIVE_REQUIREMENTS = {f"R{i:02}" for i in (3, 4, 5, 6, 8, 9, 12, 13, 14, 15, 17, 19,
                                           20, 21, 23, 26, 27, 28, 30, 31)}
TRAINED_REQUIREMENTS = {f"R{i:02}" for i in (16, 17, 18, 20, 22, 24, 25, 26, 27, 28)}
# T4's unchanged held-out plan. Register a new plan only after its own qualification.
EVALUATION_PLAN = "70293bb2509acec9f3626a87423f5a077d496e75cad3dc734f6fff853af763c4"
EVALUATION_PLANS = frozenset({EVALUATION_PLAN,
    "deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd"})
sys.path.insert(0, str(ROOT / "tool/zyren_train/src"))
from zyren_train.metrics import EpisodeMetric, aggregate
from zyren_train.regression import qualify
from zyren_train.scenario import canonical_bytes

SHA256 = re.compile(r"^[0-9a-f]{64}$")


def validate_model_parity(path, model_hash, family, *, root=ROOT):
    """Recompute the fixed 1,000-step T5 native tensor/control comparison."""
    root = Path(root).resolve()
    path = Path(path).resolve()
    widths = {"guard": {"logits": 22, "next_hidden": 128, "next_cell": 128},
              "vehicle": {"action": 3, "next_hidden": 128, "next_cell": 128}}
    if family not in widths or not path.is_relative_to(root):
        return False

    def finite(value):
        return type(value) in (int, float) and math.isfinite(value)

    def same(value, expected):
        return finite(value) and math.isclose(value, expected, rel_tol=1e-9, abs_tol=1e-12)

    def pinned(pin, maximum):
        if not isinstance(pin, dict):
            raise ValueError("Missing parity evidence")
        name = pin.get("path")
        if not isinstance(name, str) or not name or Path(name).is_absolute():
            raise ValueError("Parity evidence must use a relative path")
        source = (path.parent / name).resolve()
        size, digest = pin.get("bytes"), pin.get("sha256")
        if (not source.is_relative_to(root) or type(size) is not int or not 0 < size <= maximum
                or not isinstance(digest, str) or not SHA256.fullmatch(digest)
                or not source.is_file() or source.stat().st_size != size):
            raise ValueError("Parity evidence path or byte count differs")
        raw = source.read_bytes()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError("Parity evidence changed")
        return raw

    try:
        if path.stat().st_size > 16_777_216:
            return False
        receipt = json.loads(path.read_text())
        if (not isinstance(receipt, dict) or type(receipt.get("schema_version")) is not int
                or receipt["schema_version"] != 1 or receipt.get("status") != "passed"
                or receipt.get("provider") != "native-onnxruntime-1.23.2-cpu"
                or receipt.get("model_sha256") != model_hash
                or any(type(receipt.get(key)) is not int or receipt[key] != 1000
                       for key in ("steps", "typed_controller_steps", "completed_runs"))
                or any(type(receipt.get(key)) is not int or receipt[key] != 0
                       for key in ("live_sessions", "live_results"))
                or not finite(receipt.get("atol")) or receipt["atol"] != 1e-5
                or not finite(receipt.get("rtol")) or receipt["rtol"] != 1e-4
                or not all(isinstance(receipt.get(key), str) and SHA256.fullmatch(receipt[key])
                           for key in ("input_sequence_hash", "native_worker_sha256"))):
            return False
        assets = receipt.get("native_asset_sha256")
        if (not isinstance(assets, dict) or not 2 <= len(assets) <= 16
                or any(not isinstance(name, str) or not isinstance(digest, str)
                       or not SHA256.fullmatch(digest) for name, digest in assets.items())
                or not any("zyren_ml" in name for name in assets)
                or not any("onnxruntime" in name for name in assets)):
            return False
        tensor, controls = receipt.get("tensor_evidence"), receipt.get("control_evidence")
        width = sum(widths[family].values())
        if (not isinstance(tensor, dict) or tensor.get("dtype") != "float32-le"
                or tensor.get("shape") != [1000, 2, width]
                or tensor.get("tensor_widths") != widths[family]
                or any(type(v) is not int for v in tensor["tensor_widths"].values())
                or not isinstance(controls, dict) or type(controls.get("steps")) is not int
                or controls["steps"] != 1000):
            return False
        raw = pinned(tensor, 2_500_000)
        if len(raw) != 1000 * 2 * width * 4:
            return False
        rows = json.loads(pinned(controls, 4_000_000))
        if not isinstance(rows, list) or len(rows) != 1000:
            return False
        absolute, normalized = 0.0, 0.0
        for step, row in enumerate(rows):
            if (not isinstance(row, dict) or set(row) != ({"step", "reference", "native", "legality"}
                    if family == "guard" else {"step", "reference", "native"})
                    or type(row.get("step")) is not int or row["step"] != step):
                return False
            reference = struct.unpack_from("<" + "f" * width, raw, step * width * 8)
            native = struct.unpack_from("<" + "f" * width, raw, step * width * 8 + width * 4)
            if not all(math.isfinite(v) for v in (*reference, *native)):
                return False
            for expected, actual in zip(reference, native):
                delta = abs(actual - expected)
                absolute = max(absolute, delta)
                normalized = max(normalized, delta / (1e-5 + 1e-4 * abs(expected)))
            if normalized > 1:
                return False
            decoded = []
            for name, values in (("reference", reference), ("native", native)):
                action = row[name]
                if (not isinstance(action, dict) or set(action) != {"continuous", "discrete"}
                        or not isinstance(action["continuous"], list)
                        or not isinstance(action["discrete"], list)):
                    return False
                if family == "guard":
                    masks = row["legality"]
                    sizes = (5, 5, 5, 3, 2, 2)
                    if (not isinstance(masks, list) or len(masks) != len(sizes)
                            or any(not isinstance(mask, list) or len(mask) != size
                                   or not any(mask) or any(type(v) is not bool for v in mask)
                                   for mask, size in zip(masks, sizes))):
                        return False
                    offset, choices = 0, []
                    for mask, size in zip(masks, sizes):
                        choices.append(max((i for i, allowed in enumerate(mask) if allowed),
                                           key=lambda i: (values[offset + i], -i)))
                        offset += size
                    if (action["continuous"] or action["discrete"] != choices
                            or any(type(v) is not int for v in action["discrete"])):
                        return False
                    decoded.append(choices)
                else:
                    expected = [values[0], 0.0 if values[2] > 0 else values[1], values[2]]
                    actual = action["continuous"]
                    if (action["discrete"] or len(actual) != 3
                            or any(not finite(v) or not low <= v <= 1
                                   for v, low in zip(actual, (-1, 0, 0)))
                            or any(not finite(v) or abs(v - e) > 1e-5 + 1e-4 * abs(e)
                                   for v, e in zip(actual, expected))):
                        return False
                    decoded.append(actual)
            if family == "guard" and decoded[0] != decoded[1]:
                return False
            if family == "vehicle" and any(abs(a - e) > 1e-5 + 1e-4 * abs(e)
                                            for e, a in zip(*decoded)):
                return False
        return (same(receipt.get("max_absolute_error"), absolute)
                and same(receipt.get("max_normalized_error"), normalized))
    except (OSError, UnicodeError, ValueError, TypeError, KeyError, struct.error):
        return False


def validate(document, root=ROOT, *, release=True):
    """Return diagnostics; schema-only mode permits explicit failed/blocked work."""
    errors = []
    parity_cache = {}
    root = Path(root).resolve()

    def error(location, message):
        errors.append(f"{location}: {message}")

    def evidence(items, location):
        verified = []
        if not isinstance(items, list) or not items:
            error(location, "passed status requires evidence")
            return verified
        for index, item in enumerate(items):
            label = f"{location}[{index}]"
            if not isinstance(item, dict):
                error(label, "expected an evidence object")
                continue
            name, digest = item.get("path"), item.get("sha256")
            if not isinstance(name, str) or not name or Path(name).is_absolute():
                error(label, "evidence path must be relative to the repository")
                continue
            path = (root / name).resolve()
            if not path.is_relative_to(root):
                error(label, "evidence path escapes the repository")
                continue
            valid = False
            if not isinstance(digest, str) or not SHA256.fullmatch(digest):
                error(label, "expected a SHA256 content pin")
            elif not path.is_file():
                error(label, f"missing evidence file {name}")
            elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                error(label, f"changed evidence file {name}")
            else:
                valid = True
            if not isinstance(item.get("description"), str) or not item["description"].strip():
                error(label, "explain what this evidence establishes")
            if valid:
                verified.append(path)
        return verified

    def read_receipt(path):
        if path.stat().st_size > 16_777_216:
            return None
        try:
            value = json.loads(path.read_text())
            return value if isinstance(value, dict) else None
        except (OSError, UnicodeError, ValueError):
            return None

    def native_receipt(value, target):
        return (isinstance(value, dict) and type(value.get("schemaVersion")) is int
                and value.get("schemaVersion") == 1 and value.get("kind") == "nativeExecution"
                and value.get("status") == "passed" and value.get("skipped") is False
                and type(value.get("exitCode")) is int and value["exitCode"] == 0
                and value.get("target") == target
                and value.get("backend") == target.split("-")[1]
                and isinstance(value.get("buildMode"), str)
                and value["buildMode"] in {"debug", "profile", "release"}
                and isinstance(value.get("physicalDevice"), str)
                and bool(value["physicalDevice"].strip()))

    def trained_receipt(value, location):
        try:
            if (not isinstance(value, dict) or type(value.get("schemaVersion")) is not int
                    or value.get("schemaVersion") != 1 or value.get("kind") != "trainedArtifact"
                    or value.get("status") != "passed" or value.get("accepted") is not True):
                return False
            report_paths = evidence([value.get("evaluation")], location + ".evaluation")
            if not report_paths:
                return False
            report = read_receipt(report_paths[0])
            if (not report or type(report.get("schema_version")) is not int
                    or report.get("schema_version") != 1 or report.get("plan_hash") not in EVALUATION_PLANS):
                return False
            if hashlib.sha256(canonical_bytes(report["plan"])).hexdigest() != report["plan_hash"]:
                return False
            if (report.get("status") != "passed" or report.get("reasons") != []
                    or not isinstance(report.get("provider"), str)
                    or not all(part in {"python-onnxruntime-1.23.2-cpu", "native-onnxruntime-1.23.2-cpu"}
                               for part in report["provider"].split(";"))):
                return False
            families = {"guard", "vehicle"}
            models = value.get("models")
            parity = value.get("nativeParity")
            if not isinstance(models, dict) or set(models) != families:
                return False
            if not isinstance(parity, dict) or set(parity) != families:
                return False
            hashes = {}
            for family in sorted(families):
                model_paths = evidence([models[family]], location + ".models." + family)
                parity_paths = evidence([parity[family]], location + ".nativeParity." + family)
                if not model_paths or not parity_paths:
                    return False
                hashes[family] = models[family]["sha256"]
                key = (parity_paths[0], parity[family]['sha256'], hashes[family], family)
                if key not in parity_cache:
                    parity_cache[key] = validate_model_parity(parity_paths[0], hashes[family], family, root=root)
                if not parity_cache[key]:
                    return False
            if report.get("family_model_hashes") != hashes:
                return False
            expected = [(seed, case["scenario"]["id"], case["family"])
                        for case in report["plan"]["cases"] for seed in case["seeds"]]
            rows = [EpisodeMetric(**row) for row in report["episodes"]]
            if (len(rows) != len(expected) or report.get("requested") != len(expected)
                    or any((row.index, row.seed, row.scenario, row.family) != (i, *slot)
                           for i, (row, slot) in enumerate(zip(rows, expected)))
                    or any(row.steps < 1 for row in rows)):
                return False
            metrics = {family: aggregate([row for row in rows if row.family == family],
                        sum(slot[2] == family for slot in expected)) for family in families}
            if report.get("metrics") != metrics:
                return False
            seed_counts = {family: len({row.seed for row in rows if row.family == family})
                           for family in families}
            if report.get("layout_seed_counts") != seed_counts or any(n < 20 for n in seed_counts.values()):
                return False
            coverage = report["coverage_evidence"]
            labels = set()
            for case in report["plan"]["cases"]:
                executed = [row for row in rows if row.scenario == case["scenario"]["id"]
                            and row.status == "completed"]
                settings = case["scenario"]["settings"]
                permitted = set()
                for condition, label in ((settings.get("held_out_layout"), "unfamiliar-layouts"),
                                         (settings.get("friction_range"), "friction"),
                                         (settings.get("target_speed", 0) > 0, "moving-target"),
                                         (settings.get("curriculum_stage") in ("occlusion", "task-combinations"), "occlusion-memory"),
                                         (settings.get("curriculum_stage") in ("moving-hazards", "task-combinations"), "moving-hazards")):
                    if condition:
                        permitted.add(label)
                if any(row.fallback_steps > 0 for row in executed):
                    permitted.add("fallback-recovery")
                    if case["stress"]["miss_every"]:
                        permitted.add("missed-decisions")
                    if case["stress"]["delay_every"]:
                        permitted.add("delayed-observations")
                current = set(coverage.get(case["id"], []))
                if current and (not executed or not current <= permitted):
                    return False
                labels.update(current)
            if sorted(labels) != report.get("stress_coverage"):
                return False
            status, _ = qualify(metrics, hidden_state_leaks=report["hidden_state_leaks"],
                                reward_exploits=report["reward_exploits"], stress_coverage=labels)
            exits = report.get("worker_exit_codes")
            return (status == "passed" and report.get("worker_failures") == 0
                    and isinstance(exits, list) and bool(exits) and len(exits) <= 64
                    and all(type(code) is int and code == 0 for code in exits)
                    and report.get("worker_sha256") == report["plan"]["worker_sha256"]
                    and report.get("worker_native_sha256") == report["plan"]["worker_native_sha256"])
        except (KeyError, TypeError, ValueError, OSError):
            return False

    def status(record, location, *, required, target=None, trained=False):
        if not isinstance(record, dict):
            error(location, "missing status record")
            return
        value = record.get("status")
        if not isinstance(value, str) or value not in STATUSES:
            error(location, "status must be passed, failed, blocked or notApplicable")
            return
        if value == "passed":
            paths = evidence(record.get("evidence"), location + ".evidence")
            if target is not None and not any(native_receipt(read_receipt(path), target) for path in paths):
                error(location, "passed target requires matching successful physical native execution receipt")
            if trained and not any(trained_receipt(read_receipt(path), location) for path in paths):
                error(location, "passed trainedArtifact requires accepted pinned ONNX models, fixed-plan quality and Dart native parity")
        elif not isinstance(record.get("reason"), str) or not record["reason"].strip():
            error(location, f"{value} requires a reason")
        if required and value == "notApplicable":
            error(location, "required evidence cannot be marked notApplicable")
        elif release and required and value != "passed":
            error(location, f"release is incomplete ({value})")
        elif release and not required and value in {"failed", "blocked"}:
            error(location, f"declared applicable work is incomplete ({value})")

    if not isinstance(document, dict) or (type(document.get("schemaVersion")) is not int or document.get("schemaVersion") != 1):
        return ["completion: expected schemaVersion 1 object"]
    target_list = document.get("requiredTargets")
    if (not isinstance(target_list, list) or len(target_list) != len(TARGETS)
            or any(not isinstance(target, str) for target in target_list)
            or set(target_list) != TARGETS):
        error("requiredTargets", "must preserve all five targets in the accepted design")
    for section, expected in (("requirements", REQUIREMENTS), ("tasks", TASKS)):
        records = document.get(section)
        if not isinstance(records, dict):
            error(section, "missing record map")
            continue
        for identifier in sorted(expected - records.keys()):
            error(f"{section}.{identifier}", "missing record")
        for identifier in sorted(records.keys() - expected):
            error(f"{section}.{identifier}", "unknown record")
        for identifier in sorted(expected & records.keys()):
            record = records[identifier]
            if not isinstance(record, dict):
                error(f"{section}.{identifier}", "expected a record object")
                continue
            for dimension in DIMENSIONS:
                required = dimension in {"implemented", "automated", "documentation"}
                if section == "requirements":
                    required |= dimension == "native" and identifier in NATIVE_REQUIREMENTS
                    required |= dimension == "trainedArtifact" and identifier in TRAINED_REQUIREMENTS
                status(record.get(dimension), f"{section}.{identifier}.{dimension}", required=required, trained=dimension == "trainedArtifact")
            if section == "requirements" and identifier in NATIVE_REQUIREMENTS:
                targets = record.get("targets")
                if not isinstance(targets, dict):
                    error(f"{section}.{identifier}.targets", "missing native target records")
                    continue
                if set(targets) != TARGETS:
                    error(f"{section}.{identifier}.targets", "expected all five native targets")
                for target in sorted(TARGETS):
                    status(targets.get(target), f"{section}.{identifier}.targets.{target}", required=True, target=target)
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", type=Path,
                        default=ROOT / "plans/zyren-plugins/game-ai/completion.json")
    parser.add_argument("--check-schema", action="store_true",
                        help="check coverage and evidence pins without declaring completion")
    args = parser.parse_args()
    try:
        document = json.loads(args.path.read_text())
        errors = validate(document, release=not args.check_schema)
    except (OSError, ValueError, TypeError) as error:
        errors = [str(error)]
    print(json.dumps({"status": "failed" if errors else "passed",
                      "mode": "schema" if args.check_schema else "release",
                      "diagnostics": errors}, indent=2))
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
