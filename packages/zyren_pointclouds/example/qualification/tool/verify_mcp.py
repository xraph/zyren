"""Exercise the host-started shared MCP process. No external service."""
import json
import pathlib
import subprocess
import sys
import shlex

binary = shlex.split(sys.argv[1])
report_path = pathlib.Path(sys.argv[2])


def exercise(granted):
    process = subprocess.Popen(binary + (["--allow-filter"] if granted else []), stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=pathlib.Path(__file__).resolve().parents[1])
    identifier = 0
    evidence = []

    def call(method, params=None):
        nonlocal identifier
        identifier += 1
        request = {"jsonrpc": "2.0", "id": identifier, "method": method}
        if params is not None:
            request["params"] = params
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        assert response["id"] == identifier, response
        assert "error" not in response, response
        evidence.append({"request": request, "response": response})
        return response["result"]

    def tool(name, arguments):
        result = call("tools/call", {"name": name, "arguments": arguments})
        content = json.loads(result["content"][0]["text"])
        return content

    try:
        call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                            "clientInfo": {"name": "reality-qualification", "version": "1"}})
        process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        process.stdin.flush()
        listed = call("tools/list")
        assert {"inspect_scene", "get_renderer_capabilities", "agent_discover", "agent_query", "agent_command"}.issubset(
            {t["name"] for t in listed["tools"]})
        tool("get_renderer_capabilities", {})
        discovered = tool("agent_discover", {})["agentDiscovery"]["providers"]
        assert len(discovered) == 3, discovered
        target = {"providerId": "zyren.pointclouds.stream", "instanceId": "points"}
        inspect = tool("agent_query", {**target, "tool": "inspect"})["agentResult"]
        assert inspect["status"] == "ok", inspect
        assert inspect["data"]["stream"]["visibleChunks"] == 2, inspect
        command = {**target, "tool": "filter", "arguments": {"classifications": [2]},
                   "expectedRevision": inspect["revision"], "idempotencyKey": "filter-1"}
        result = tool("agent_command", command)["agentResult"]
        assert result["status"] == ("ok" if granted else "denied"), result
        if granted:
            retry = tool("agent_command", command)["agentResult"]
            assert retry == result, retry
            inspect = tool("agent_query", {**target, "tool": "inspect"})["agentResult"]
            stale = tool("agent_command", {**target, "tool": "undoFilter", "expectedRevision": 0,
                                          "idempotencyKey": "stale-undo"})["agentResult"]
            assert stale["status"] == "stale", stale
            undo = tool("agent_command", {**target, "tool": "undoFilter", "expectedRevision": inspect["revision"],
                                         "idempotencyKey": "undo-1"})["agentResult"]
            assert undo["status"] == "ok", undo
        estimate = tool("agent_query", {"providerId": "zyren.splats.stream", "instanceId": "gaussians", "tool": "estimate",
                                         "arguments": {"x": 64, "y": 64}})["agentResult"]
        assert estimate["status"] == "ok", estimate
        assert estimate["data"]["hits"][0]["measurementSurface"] is False
        return evidence
    finally:
        process.stdin.close()
        process.wait(timeout=30)
        stderr = process.stderr.read()
        assert process.returncode == 0, stderr
        assert "REALITY_MCP_CLEANUP decoded=0 requests=0" in stderr, stderr


report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps({"granted": exercise(True), "denied": exercise(False)}, indent=2) + "\n")
print("Live shared MCP: discovery, native capabilities, queries, denial, filter, retry, stale guard, undo and EOF cleanup passed.")
