"""Verify the shared MCP transport against every native scientific representation."""
import json
from pathlib import Path
import selectors
import subprocess
import sys


def main():
    dart = sys.argv[1]
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    transcript = []
    with (output / "stderr.log").open("w") as errors:
        process = subprocess.Popen([dart, "run", "example/field_agent_host.dart", str(output)],
                                   cwd=Path(__file__).resolve().parents[1], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        request_id = 0

        def request(method, params):
            nonlocal request_id
            request_id += 1
            message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
            assert selector.select(300 if method == "initialize" else 90), "MCP response timeout"
            response = json.loads(process.stdout.readline())
            transcript.append({"request": message, "response": response})
            assert "error" not in response, response
            return response["result"]

        def tool(name, arguments):
            return request("tools/call", {"name": name, "arguments": arguments})["structuredContent"]

        def call(name, args=None, command=False, revision=None, key=None, provider="zyren.scientific.field", instance="native-field"):
            arguments = {"providerId": provider, "instanceId": instance, "tool": name, "arguments": args or {}}
            if revision is not None:
                arguments["expectedRevision"] = revision
            if key:
                arguments["idempotencyKey"] = key
            return tool("agent_command" if command else "agent_query", arguments)["agentResult"]

        try:
            request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "scientific-field-fixture", "version": "1"}})
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            process.stdin.flush()
            providers = tool("agent_discover", {})["agentDiscovery"]["providers"]
            provider = next(p for p in providers if p["providerId"] == "zyren.scientific.field")
            assert len(provider["tools"]) == 11
            state = call("inspect")
            revision = state["revision"]
            checks = []
            for mode in ["isosurface", "vectors", "streamline", "volume", "slice"]:
                args = {"representation": mode}
                denied = call("set_representation", args, revision=revision, key=mode)
                assert denied["status"] == "denied", denied
                changed = call("set_representation", args, True, revision, mode)
                assert changed["status"] == "ok", changed
                retry = call("set_representation", args, True, revision, mode)
                assert retry["revision"] == changed["revision"]
                revision = changed["revision"]
                if mode in ["vectors", "streamline"]:
                    assert changed["data"]["sourceId"] == "synthetic:rotation:v1"
                    assert changed["data"]["unit"]["symbol"] == "m/s"
                    assert changed["data"]["time"] is None
                if mode == "isosurface":
                    pick = call("pick", {"x": 320, "y": 320}, provider="zyren.viewport", instance="capture-view")
                    hit = pick["data"]["hits"][0]
                    sample = call("sample_triangle", {"runtimeObjectId": hit["object"]["runtimeId"],
                                  "sceneRevision": pick["data"]["sceneRevision"], "triangleIndex": hit["triangleIndex"],
                                  "barycentric": hit["barycentric"]}, revision=revision)
                    assert sample["status"] == "ok" and sample["data"]["sourceCell"] is not None, sample
                    assert sample["data"]["isosurfaceValue"] == 293
                checks.append(mode)
            changed = call("seek", {"time": .5}, True, revision, "time-half")
            assert changed["status"] == "ok" and changed["data"]["time"] == .5, changed
            assert len(changed["data"]["frames"]) == 2
            stale = call("set_parameters", {"threshold": 290}, True, revision, "stale")
            assert stale["status"] == "stale"
            images = sorted(output.glob("field-*.png"))
            assert len(images) == 7, len(images)
            pixels = [p.read_bytes() for p in images]
            assert all(a != b for a, b in zip(pixels, pixels[1:])), "A mutation did not change the native image"
            assert pixels[0] == pixels[5], "Returning to the same slice changed its image"
            revision = changed["revision"]
            history = call("history")
            assert history["data"]["canUndo"]
            denied = call("undo", revision=revision, key="undo-time")
            assert denied["status"] == "denied"
            restored = call("undo", command=True, revision=revision, key="undo-time")
            assert restored["status"] == "ok" and restored["data"]["time"] is None, restored
            retry = call("undo", command=True, revision=revision, key="undo-time")
            assert retry["revision"] == restored["revision"]
            assert (output / "field-8.png").read_bytes() == pixels[0]
            replayed = call("redo", command=True, revision=restored["revision"], key="redo-time")
            assert replayed["status"] == "ok" and replayed["data"]["time"] == .5, replayed
            assert (output / "field-9.png").read_bytes() == pixels[6]
            cleared = call("clear_history", command=True, revision=replayed["revision"], key="clear")
            assert cleared["status"] == "ok" and not cleared["data"]["history"]["canUndo"]
            capture = json.loads((output / "capture.json").read_text())
            process.stdin.close()
            assert process.wait(timeout=20) == 0
            report = {"status": "passed", "representations": checks, "temporalSeek": .5,
                      "checks": ["discovery", "read-only denial", "authorized commands", "retry", "stale revision", "real pick to source cell", "distinct native images", "history, undo, redo and clear", "native restored images", "EOF cleanup"],
                      "native": capture}
            (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2))
        finally:
            (output / "transcript.json").write_text(json.dumps(transcript, indent=2) + "\n")
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    main()
