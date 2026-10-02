"""Run a real stdio MCP session against the native synthetic-data example."""
import json
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile


def main():
    dart = sys.argv[1] if len(sys.argv) > 1 else "dart"
    output = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(tempfile.mkdtemp(prefix="zyren-scientific-mcp-"))
    output.mkdir(parents=True, exist_ok=True)
    transcript = []
    with (output / "host-stderr.log").open("w") as errors:
        process = subprocess.Popen(
            [dart, "run", "example/agent_host.dart", str(output.resolve())],
            cwd=Path(__file__).resolve().parents[1], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1,
        )
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        request_id = 0

        def request(method, params):
            nonlocal request_id
            request_id += 1
            message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
            assert selector.select(90), f"MCP response timeout; inspect {output / 'host-stderr.log'}"
            line = process.stdout.readline()
            response = json.loads(line)
            transcript.append({"request": message, "response": response})
            assert response.get("id") == request_id, response
            assert "error" not in response, response
            return response["result"]

        def tool(name, args):
            return request("tools/call", {"name": name, "arguments": args})["structuredContent"]

        def query(provider, instance, tool_name, args=None, revision=None):
            arguments = {"providerId": provider, "instanceId": instance, "tool": tool_name, "arguments": args or {}}
            if revision is not None:
                arguments["expectedRevision"] = revision
            return tool("agent_query", arguments)["agentResult"]

        try:
            request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "scientific-fixture", "version": "1"}})
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            process.stdin.flush()
            listed = request("tools/list", {})["tools"]
            assert next(t for t in listed if t["name"] == "inspect_scene")["annotations"]["readOnlyHint"]
            discovery = tool("agent_discover", {})["agentDiscovery"]
            scientific = next(p for p in discovery["providers"] if p["providerId"] == "zyren.scientific")
            assert len(scientific["tools"]) == 6
            state = query("zyren.scientific", "synthetic-temperature", "inspect")
            assert state["status"] == "ok" and state["revision"] == 0
            assert state["data"]["dataset"]["sourceKind"] == "synthetic"
            context = query("zyren.viewport", "capture-view", "context")
            assert context["data"]["hostState"]["presentation"] == "offscreen-native-readback"
            assert context["data"]["presentedFrame"] is None
            picked = query("zyren.viewport", "capture-view", "pick", {"x": 128, "y": 512})
            assert picked["status"] == "ok", picked
            hit = picked["data"]["hits"][0]
            assert hit["object"]["metadata"]["sourceId"] == "synthetic:affine-temperature:v1"
            sampled = query("zyren.scientific", "synthetic-temperature", "sample_triangle", {
                "runtimeObjectId": hit["object"]["runtimeId"], "triangleIndex": hit["triangleIndex"],
                "barycentric": hit["barycentric"], "sceneRevision": picked["data"]["sceneRevision"],
            }, revision=0)
            assert sampled["status"] == "ok", sampled
            error = abs(sampled["data"]["value"] - 283.95)
            assert error < 1e-5, sampled
            assert sampled["data"]["pixelVisibility"] == "unknown"
            command = {"providerId": "zyren.scientific", "instanceId": "synthetic-temperature", "tool": "set_slice", "arguments": {"axis": "z", "index": 2}, "expectedRevision": 0, "idempotencyKey": "next-plane"}
            denied = tool("agent_query", command)["agentResult"]
            assert denied["status"] == "denied", denied
            changed = tool("agent_command", command)["agentResult"]
            assert changed["status"] == "ok" and changed["revision"] == 1, changed
            retried = tool("agent_command", command)["agentResult"]
            assert retried["revision"] == 1
            stale = tool("agent_command", {**command, "idempotencyKey": "old-state"})["agentResult"]
            assert stale["status"] == "stale", stale
            assert (output / "synthetic-1.png").read_bytes() != (output / "synthetic-2.png").read_bytes()
            assert not (output / "synthetic-3.png").exists(), "Retry rendered an additional state"
            capture = json.loads((output / "capture.json").read_text())
            assert capture["viewRevision"] == 1
            process.stdin.close()
            assert process.wait(timeout=15) == 0
            report = {"status": "passed", "sourceKind": "synthetic", "sampleErrorK": error,
                      "native": capture, "checks": ["discovery", "schema queries", "viewport pick", "scalar join", "read-only denial", "authorized slice change", "native pixel change", "retry", "stale revision", "EOF cleanup"],
                      "presentation": "offscreen; no human viewport or device qualification"}
            (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2))
            print(output)
        finally:
            (output / "transcript.json").write_text(json.dumps(transcript, indent=2) + "\n")
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    main()
