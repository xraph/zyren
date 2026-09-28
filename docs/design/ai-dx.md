# AI developer tools

Zyren's AI interface reads the scene you are running. It uses the same inspector
as the workbench and keeps inference outside the renderer.

## Contract

`zyren_devtools` owns a version 1 JSON contract and seven read-only operations:
`inspect_scene`, `inspect_object`, `get_renderer_capabilities`,
`get_scene_issues`, `capture_frame_stats`, `diagnose_scene`, and `export_report`.
Every response identifies the session and schema. Scene pages carry a revision;
you can require that revision on later pages to detect edits during inspection.
Object IDs belong to one inspector attachment. They are not source identifiers.

Diagnostics check inherited visibility, camera validity and conservative bounds
against the native clip volume (depth 0 to 1). Bounds overlap is inconclusive:
occlusion, shading and presentation still need a rendered frame. Missing frame
measurements remain null. CPU timings cover Dart work, not native driver work.
Reports include bounded metadata, issues and frame history, never geometry
payloads, texture bytes, credentials or arbitrary exception objects. Reports are
diagnostic captures, not self-contained asset reproductions.

## Connections

The pure Dart inspection API has no networking. A separate `io.dart` adapter
binds explicitly to IPv4 loopback on an ephemeral port and requires a random
bearer token. It rejects browser-origin requests, limits request sizes and
closes on disposal. Enabling it is the host application's decision.

The `zyren` CLI calls this adapter. Its `mcp` command exposes the same operations
over newline-delimited stdio JSON-RPC, with MCP 2025-11-25 initialization and
tool discovery. Stdout contains protocol messages only. Credentials come from
`ZYREN_DEVTOOLS_TOKEN`; endpoint discovery stays explicit. There is no cloud
provider dependency, arbitrary code execution or scene mutation in this API.

The workbench enables the bridge only in debug builds when you pass
`--dart-define=ZYREN_AI_DX=true`. Runtime issues feed a bounded history. Tests use
real scene graphs and real loopback sockets; native verification exercises the
workbench's Metal presentation path through the external CLI and MCP process.

## Authoring and follow-up

A versioned agent guide and compiled recipes teach the current package imports,
plugin lifecycle and capability checks. An assistant can use these references to
write a normal Dart patch that you review and run. Automatic scene mutations,
asset-complete replay, a hosted model chat UI and a Flutter DevTools extension
are separate features. None are required to connect an MCP client to this API.
