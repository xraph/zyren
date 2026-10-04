#!/usr/bin/env python3
"""Run real GameLab profile builds and retain failed qualification evidence."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import re
import stat
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "examples/game_lab"
PROFILES = Path(__file__).with_name("game_ai_profiles.json")


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Expected an object in {path}")
    return value


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def physical_device(devices: list[dict], device_id: str) -> dict:
    selected = [d for d in devices if d.get("id") == device_id]
    if len(selected) != 1:
        raise ValueError("Select one connected device by its exact Flutter device ID")
    device = selected[0]
    platform = device.get("targetPlatform", "")
    if device.get("emulator") is not False or not platform.startswith(
        ("darwin", "android", "ios", "windows", "linux")
    ):
        raise ValueError("Qualification requires a physical native device")
    return device


def source_hash() -> str:
    # Include uncommitted and new source in this shared checkout's build identity.
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, check=True, stdout=subprocess.PIPE,
    )
    digest = hashlib.sha256()
    for name in sorted(set(result.stdout.decode().split("\0")) - {""}):
        path = ROOT / name
        if not path.is_file():
            continue
        digest.update(name.encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def file_pin(path: Path, *, max_bytes: int = 8 * 1024**3) -> dict:
    if path.stat().st_size > max_bytes:
        raise ValueError("Native artifact byte bound exceeded")
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            if size > max_bytes:
                raise ValueError("Native artifact byte bound exceeded")
            digest.update(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}


def bundle_inventory(bundle: Path, *, max_files: int = 100000,
                     max_bytes: int = 8 * 1024**3) -> dict:
    """Pin all regular bytes and internal link metadata without following links."""
    if max_files < 1 or max_bytes < 1 or bundle.is_symlink() or not bundle.is_dir():
        raise ValueError("Invalid native bundle or inventory bounds")
    base = bundle.resolve()
    entries, total, visited = [], 0, 0
    for directory, dirs, files in os.walk(bundle, followlinks=False):
        for name in sorted(dirs + files):
            visited += 1
            if visited > max_files:
                raise ValueError("Native bundle entry bound exceeded")
            path = Path(directory) / name
            info = path.lstat()
            relative = path.relative_to(bundle).as_posix()
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                try:
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise ValueError("Unresolvable bundle symlink") from error
                if Path(target).is_absolute() or not resolved.is_relative_to(base):
                    raise ValueError("Native bundle symlink escapes its inventory")
                entry = {"path": relative, "kind": "symlink", "target": target,
                         "mode": stat.S_IMODE(info.st_mode)}
            elif stat.S_ISREG(info.st_mode):
                if total + info.st_size > max_bytes:
                    raise ValueError("Native bundle byte bound exceeded")
                entry = {"path": relative, "kind": "file", **file_pin(path),
                         "mode": stat.S_IMODE(info.st_mode)}
                total += entry["bytes"]
                if total > max_bytes:
                    raise ValueError("Native bundle byte bound exceeded")
            elif stat.S_ISDIR(info.st_mode):
                continue
            else:
                raise ValueError("Unsupported native bundle entry")
            entries.append(entry)
            if len(entries) > max_files:
                raise ValueError("Native bundle file bound exceeded")
    if not entries:
        raise ValueError("Native bundle is empty")
    entries.sort(key=lambda item: item["path"])
    digest = hashlib.sha256(json.dumps(entries, sort_keys=True,
                                      separators=(",", ":")).encode()).hexdigest()
    return {"kind": "bundle", "totalBytes": total, "files": entries,
            "sha256": digest}


def build_artifacts(platform: str, mode: str) -> list[dict]:
    if platform.startswith("android"):
        files = sorted(APP.glob(f"build/app/outputs/flutter-apk/*{mode}*.apk"))
        return [{"path": str(p.relative_to(APP)), "kind": "file", **file_pin(p)}
                for p in files if p.is_file() and not p.is_symlink()]
    pattern = (f"build/macos/Build/Products/{mode.title()}/*.app"
               if platform.startswith("darwin") else "build/ios/iphoneos/*.app"
               if platform.startswith("ios") else f"build/windows/x64/runner/{mode.title()}"
               if platform.startswith("windows") else f"build/linux/*/{mode}/bundle")
    return [{"path": str(p.relative_to(APP)), **bundle_inventory(p)}
            for p in sorted(APP.glob(pattern))]


def validate_receipt(receipt: dict, profile: dict, device: dict,
                     build_hash: str, *, smoke: bool = False,
                     inputs_stable: bool = True) -> list[str]:
    errors = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    def integer(value: object, minimum: int = 0) -> bool:
        return type(value) is int and value >= minimum

    def finite(value: object, minimum: float = 0) -> bool:
        return type(value) in (int, float) and math.isfinite(value) and value >= minimum

    def pins(value: object) -> bool:
        return (isinstance(value, list) and bool(value) and
                all(isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v) for v in value))

    require(type(receipt.get("schemaVersion")) is int and receipt["schemaVersion"] == 1, "unsupported measurement schema")
    require(receipt.get("profile") == profile, "profile differs from requested load")
    identity = receipt.get("identity")
    if not isinstance(identity, dict):
        identity = {}
    require(identity.get("device") == device["id"] and
            identity.get("physicalDevice") is True, "physical device identity differs")
    require(identity.get("buildHash") == build_hash, "build inputs differ")
    require(inputs_stable is True or smoke, "source changed during measured build/run")
    require(identity.get("buildMode") in ("profile", "release"),
            "build mode is not measured production code")
    platform = device.get("targetPlatform", "")
    expected = ("metal" if platform.startswith(("darwin", "ios")) else
                "vulkan" if platform.startswith(("android", "linux")) else "dx12")
    require(str(identity.get("renderer", "")).lower() == expected,
            "native renderer differs from target")
    require(identity.get("provider") == "native-onnxruntime-1.23.2-cpu",
            "native inference provider is unverified")
    require(isinstance(identity.get("os"), str) and bool(identity["os"]), "OS identity missing")
    require(isinstance(identity.get("gameHash"), str) and
            re.fullmatch(r"[0-9a-f]{64}", identity["gameHash"]) is not None,
            "game identity missing")
    require(pins(identity.get("modelHashes")) and pins(identity.get("schemaHashes")),
            "model/schema identities missing")
    for key in ("loadVerified", "actorLoadVerified", "nativePresentation", "cleanupVerified"):
        require(receipt.get(key) is True, f"{key} is unverified")
    require(profile["cameras"] == 0 or receipt.get("visualInputsVerified") is True,
            "native visual inputs unverified")
    require(type(receipt.get("readbackBytes")) is int and receipt["readbackBytes"] == 0, "presentation used CPU readback")
    for prefix, keys in (("native", {"sessions", "renderers", "retiring",
                                     "surfaces" if platform.startswith(("android", "linux", "windows"))
                                     else "heldDrawables"}),
                         ("ml", {"sessions", "results", "runs"}),
                         ("physics", {"worlds", "bodies"})):
        before, after = (receipt.get(prefix + "Owners" + suffix) for suffix in ("Before", "After"))
        require(isinstance(before, dict) and isinstance(after, dict) and
                keys.issubset(before) and before == after and
                all(integer(v) for v in before.values()) and
                all(integer(v) for v in after.values()),
                f"{prefix} native owners did not return to the measured baseline")
    lifecycle = receipt.get("lifecycle")
    required_lifecycle = {"camera-movement", "spawn", "despawn", "pause", "resume", "renderer-recreated"}
    require(isinstance(lifecycle, list) and len(lifecycle) == 6 and
            all(isinstance(v, str) for v in lifecycle) and set(lifecycle) == required_lifecycle,
            "native lifecycle coverage differs")
    for key in ("modelBytes", "peakRssBytes", "peakTensorBytes", "peakRecurrentBytes"):
        require(integer(receipt.get(key), 1), f"{key} measurement missing")
    require(type(receipt.get("invalidActions")) is int and receipt["invalidActions"] == 0 and
            type(receipt.get("staleActionsApplied")) is int and receipt["staleActionsApplied"] == 0,
            "invalid or stale actions applied")
    due, completed, missed = (receipt.get(k) for k in
                              ("dueDecisions", "completedDecisions", "missedDecisions"))
    valid_decisions = all(integer(v) for v in (due, completed, missed)) and due == completed + missed
    require(valid_decisions and completed > 0, "decision accounting differs")
    duration = receipt.get("durationSeconds")
    frames = receipt.get("frames")
    require(finite(duration, 1) and integer(frames, 1), "native duration/frame counts missing")

    def samples(name: str, budget: float | None = None) -> list[int]:
        value = receipt.get(name)
        raw = value.get("raw") if isinstance(value, dict) else None
        if (not isinstance(raw, list) or not 0 < len(raw) <= 1000000 or
                any(not integer(v) for v in raw)):
            errors.append(f"{name} raw samples invalid")
            return []
        ordered = sorted(raw)
        require(type(value.get("count")) is int and value["count"] == len(raw),
                f"{name} raw count differs")
        for field, fraction in (("p50", .5), ("p95", .95), ("p99", .99)):
            actual = ordered[math.ceil(len(raw) * fraction) - 1]
            require(finite(value.get(field)) and value[field] == actual,
                    f"{name} {field} differs from raw samples")
            if field == "p95" and budget is not None and not smoke:
                require(actual <= budget, f"{name} p95 exceeds budget")
        return raw

    presentation = samples("presentationMicros", profile["frameBudgetMs"] * 1000)
    flutter = samples("flutterFrameMicros", profile["frameBudgetMs"] * 1000)
    full = samples("fullFrameMicros", profile["frameBudgetMs"] * 1000)
    cpu = samples("gamePerceptionCpuMicros", profile["schedulingBudgetMs"] * 1000)
    inference = samples("inferenceRoundTripMicros")
    if receipt.get("clockWakeLatenessMicros") is not None:
        clock_lateness = samples("clockWakeLatenessMicros")
        clock_pending = samples("clockPendingSteps")
        clock_steps = receipt.get("clockAdvancedSteps")
        clock_dropped = receipt.get("clockDroppedSeconds")
        require(len(clock_lateness) == len(clock_pending) and
                all(value <= 64 for value in clock_pending) and
                integer(clock_steps) and clock_steps == len(cpu) and
                clock_steps <= len(clock_lateness), "realtime clock sample coverage differs")
        require(finite(clock_dropped) and clock_dropped >= 0,
                "dropped simulation time measurement missing")
        if not smoke:
            require(clock_dropped == 0, "simulation time was dropped")
    elif not smoke:
        errors.append("realtime clock measurements missing")
    render_build = samples("nativeRenderBuildMicros")
    render_submit = samples("nativeRenderSubmitMicros")
    for field in ("nativePrepareMicros", "nativeEncodeMicros", "nativeCompletionWaitMicros"):
        if receipt.get(field) is not None:
            require(len(samples(field)) <= frames, f"{field} coverage exceeds frames")
    require(len(render_build) == frames and len(render_submit) == frames,
            "native rendering sample coverage differs")
    if receipt.get("nativeRenderGpuMicros") is not None:
        require(len(samples("nativeRenderGpuMicros")) <= frames,
                "native GPU sample coverage differs")
    sizes = receipt.get("nativeOutputSizes")
    valid_sizes = (isinstance(sizes, list) and 0 < len(sizes) <= 32 and
                   all(isinstance(s, dict) and integer(s.get("width"), 1) and
                       s["width"] <= 32768 and integer(s.get("height"), 1) and
                       s["height"] <= 32768 and integer(s.get("frames"), 1) for s in sizes))
    require(valid_sizes and len({(s["width"], s["height"]) for s in sizes}) == len(sizes) and
            sum(s["frames"] for s in sizes) == frames,
            "native output dimensions or frame coverage missing")
    if smoke:
        require(receipt.get("status") == "failed" and
                isinstance(receipt.get("diagnostics"), list) and
                "duration" in receipt["diagnostics"], "short run improperly qualifies")
    else:
        require(valid_sizes and len(sizes) == 1,
                "sustained output size changed during measurement")
        require(receipt.get("status") == "passed" and receipt.get("diagnostics") == [],
                "sustained profile reports failed gates")
        require(finite(duration, profile["seconds"]), "sustained duration did not pass")
        if finite(duration, 1) and integer(frames):
            require(frames >= duration * 60 * .95, "sustained presentation count differs")
            require(len(full) == frames and frames - 3 <= len(presentation) <= frames and
                    len(flutter) >= duration * 60 * .95 and
                    len(cpu) >= duration * profile["fixedHz"] * .95,
                    "sustained raw sample coverage differs")
        if valid_decisions and finite(duration):
            rate = profile["guards"] * profile["guardHz"] + profile["vehicles"] * profile["vehicleHz"]
            require(due >= duration * rate * .95 and due > 0 and
                    completed / due >= profile["minimumReadyFraction"], "decision deadlines did not pass")
            # A batch may serve many actors. Even then, the fastest active group
            # needs one measured inference round trip per decision interval.
            batch_rate = max(profile["guardHz"] if profile["guards"] else 0,
                             profile["vehicleHz"] if profile["vehicles"] else 0)
            require(len(inference) >= duration * batch_rate * .95,
                    "sustained inference sample coverage differs")
    return errors


def summarize(runs: list[dict], profiles: list[dict], smoke: bool) -> dict:
    results = {}
    for profile in profiles:
        selected = [r for r in runs if r["profile"] == profile["id"]]
        count = 1 if smoke else profile["repetitions"]
        okay = (len(selected) == count and
                {r.get("repetition") for r in selected} == set(range(1, count + 1)) and
                all(isinstance(r.get("comparisonKey"), str) and
                    re.fullmatch(r"[0-9a-f]{64}", r["comparisonKey"]) for r in selected) and
                len({r["comparisonKey"] for r in selected}) == 1 and
                all(r["verified"] and (smoke or r.get("inputsStable") is True) for r in selected))
        results[profile["id"]] = {
            "status": ("smokeUnstable" if okay and smoke and any(r.get("inputsStable") is not True for r in selected)
                       else "smokePassed" if okay and smoke else "passed" if okay else "failed"),
            "requiredRepetitions": count,
            "runs": selected,
        }
    return {"schemaVersion": 1, "status": ("smokeUnstable" if any(r.get("inputsStable") is not True for r in runs)
                                                      else "smokeOnly") if smoke else
            "passed" if all(p["status"] == "passed" for p in results.values()) else "failed",
            "profiles": results}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--profile", action="append")
    parser.add_argument("--asset", help="Asset registered in the GameLab bundle")
    parser.add_argument("--mode", choices=("profile", "release"), default="profile")
    parser.add_argument("--smoke", action="store_true", help="One 10-second lifecycle check, never qualification")
    parser.add_argument("--output", type=Path, default=ROOT / "build/qualification/game-ai" /
                        dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    args = parser.parse_args()
    catalog = read_json(PROFILES)["profiles"]
    names = args.profile or ["mobile-structured", "desktop-structured", "mobile-visual", "desktop-visual"]
    if len(set(names)) != len(names) or any(n not in catalog for n in names):
        parser.error("Choose unique profiles from " + ", ".join(catalog))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    try:
        discovery = subprocess.run(["fvm", "flutter", "devices", "--machine"], cwd=ROOT,
                                   capture_output=True, text=True, check=True, timeout=90)
        device = physical_device(json.loads(discovery.stdout), args.device)
    except (ValueError, subprocess.SubprocessError) as error:
        write_json(output / "summary.json", {"status": "blocked", "reason": str(error)})
        return 2
    profiles = [catalog[n] for n in names]
    runs = []
    for profile in profiles:
        for repetition in range(1 if args.smoke else profile["repetitions"]):
            stem = f"{profile['id']}-{repetition + 1}"
            receipt_path, log_path = output / f"{stem}.json", output / f"{stem}.log"
            if receipt_path.exists() or log_path.exists():
                parser.error(f"Refusing to overwrite existing run {stem}; choose a fresh output directory")
            build_hash = source_hash()
            asset = args.asset or ("games/vehiclePlayground.zygame" if profile["id"] ==
                                   "reference-vehicle" else "games/exploration.zygame")
            command = ["fvm", "flutter", "drive", "--no-pub", f"--{args.mode}", "-d", device["id"],
                       "--driver=test_driver/benchmark.dart", "--target=integration_test/benchmark_test.dart",
                       "--dart-define=RUN_GAME_BENCHMARK=true",
                       f"--dart-define=GAME_BENCHMARK_PROFILE={profile['id']}",
                       f"--dart-define=GAME_BENCHMARK_ASSET={asset}",
                       f"--dart-define=GAME_BENCHMARK_DEVICE={device['id']}",
                       f"--dart-define=GAME_BENCHMARK_BUILD_HASH={build_hash}",
                       "--dart-define=GAME_BENCHMARK_PHYSICAL=true",
                       f"--dart-define=GAME_BENCHMARK_SMOKE={str(args.smoke).lower()}"]
            timed_out = False
            with log_path.open("w") as log:
                try:
                    result = subprocess.run(command, cwd=APP, stdout=log, stderr=subprocess.STDOUT,
                                            env={**os.environ, "GAME_BENCHMARK_RECEIPT": str(receipt_path)},
                                            timeout=1800)
                    code = result.returncode
                except subprocess.TimeoutExpired:
                    timed_out, code = True, -1
            if not receipt_path.exists():
                write_json(receipt_path, {"status": "failed", "profile": profile,
                                          "diagnostics": ["Driver timed out" if timed_out else
                                                          "Driver produced no native receipt"]})
            after_hash = source_hash()
            inputs_stable = build_hash == after_hash
            receipt = {}
            try:
                receipt = read_json(receipt_path)
                errors = validate_receipt(receipt, profile, device, build_hash, smoke=args.smoke,
                                          inputs_stable=inputs_stable)
            except (ValueError, TypeError, KeyError) as error:
                errors = [f"Invalid receipt: {error}"]
            try:
                artifacts = build_artifacts(device["targetPlatform"], args.mode)
            except (OSError, ValueError) as error:
                artifacts = []
                errors.append(f"Invalid native artifact: {error}")
            if not artifacts:
                errors.append("No built native artifact")
            if code != 0:
                errors.append(f"Driver exit {code}")
            comparison = None
            if not errors:
                comparison = hashlib.sha256(json.dumps({
                    "sourceHash": build_hash, "identity": receipt["identity"], "profile": profile,
                    "outputSizes": sorted((s["width"], s["height"]) for s in receipt["nativeOutputSizes"]),
                }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            runs.append({"profile": profile["id"], "repetition": repetition + 1,
                         "comparisonKey": comparison,
                         "verified": not errors, "diagnostics": errors, "exitCode": code,
                         "receipt": receipt_path.name, "log": log_path.name,
                         "sourceHash": build_hash, "sourceHashBefore": build_hash,
                         "sourceHashAfter": after_hash, "inputsStable": inputs_stable,
                         "status": "failed" if errors else "smokeUnstable" if args.smoke and not inputs_stable
                         else "smokePassed" if args.smoke else "passed",
                         "artifacts": artifacts, "command": command})
            write_json(output / "summary.json", {**summarize(runs, profiles, args.smoke), "device": device})
            print(f"{stem}: {'verified' if not errors else 'failed'} ({receipt_path})", flush=True)
    return 0 if all(r["verified"] for r in runs) else 1


if __name__ == "__main__":
    raise SystemExit(main())
