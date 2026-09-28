# Remote quantized-mesh terrain

You can load a quantized-mesh 1.0 terrain layer through the existing byte resolver
and render it with TerrainPlugin. Keep HTTP, credentials and GPU allocation out
of the decoder. Work in the main checkout as requested.

The format authority is the CesiumGS quantized-mesh README and layer.json
specification. Support EPSG:4326/TMS, finite zoom pyramids and static availability.
Reject parent layers, nonzero minimum zoom and dynamic metadata availability.
Keep a parent when any child is missing, since this slice does not synthesize
fill tiles. Use a neutral surface texture. Provider imagery remains separate.

## Task 1: Bounded mesh decoder

Produce QuantizedMeshDecoder and immutable QuantizedMeshLimits. Test 16/32-bit
indices, zigzag deltas, high-water marks, finite headers, truncation, limits,
edge validation, skirts, local ECEF precision, north-up UVs and oct normals.
Unknown extensions can be skipped only after their length is checked.

Write and run the decoder tests first. Expected: missing implementation fails.
Implement the decoder, run its tests and the geospatial suite. Expected: pass.
Commit the checked decoder and fixtures.

## Task 2: Remote source

Consume the decoder through QuantizedMeshTerrainSource.open with an injected
ByteSourceResolver, dataset identity, cancellation, source policy and limits.
Produce TileMetadata bounds and reservations without downloading tile bodies.
Validate manifest structure, coordinates, templates and effective URIs. Request
oct normals when advertised. Reject unavailable tiles and incompatible sources
before reading. Keep credentials out of source identity and error text.

Write and run source tests first. Expected: missing adapter fails. Implement it
and test HTTP transport, gzip, cancellation, policy, malformed data, byte limits,
source replacement and explicit failure/retry. Expected: pass. Commit.

## Task 3: Native evidence and review

Render HTTP-delivered fixtures with TerrainPlugin on native Metal. Check pixel
coverage, parent fallback, refinement, resize and cleanup. Run the affected
package suite, analyzer and package-boundary check. Expected: pass.

Review the complete owned diff with one fresh-context reviewer, then address
material findings with regression tests. Update parity evidence and the roadmap.
Commit locally. Do not push or merge.

## Review focus

Check hostile counts before allocation, alignment at 65,536 vertices, URI policy
after redirects, sparse availability coverage, bounds at poles and the dateline,
finite GPU values, and cancellation after a resolver ignores the signal.
Payload budgets cover final CPU/GPU data. Temporary decode allocations have
separate finite count limits and must be documented without claiming an RSS cap.
