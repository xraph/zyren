# Native ML device probe

You can run the same authored linear, recurrent and CNN fixtures on Android and
iOS through the package's native CPU provider. This app does not load trained
policies or use a remote service. The worker owns its native sessions in an
isolate and reports real native counters after cleanup. Runtime license and
third-party notices are included in the asset bundle.

From this directory, with the workspace already resolved and the package's
`ios_deployment_target: 16` hook declaration in the workspace pubspec:

```sh
fvm flutter test --no-pub integration_test/native_probe_test.dart -d DEVICE_ID
```

For a wireless Apple device, use Flutter's driver entry with port publication:

```sh
fvm flutter drive --no-pub --driver=test_driver/integration_test.dart \
  --target=integration_test/native_probe_test.dart -d DEVICE_ID --publish-port
```

The integration test requires 1,032 completed native runs: 30 load/run/release
cycles, 1,000 recurrent steps with explicit state resets, one CNN 84x84 run and one
int64/bool run. It compares values against the local reference fixtures, rejects
corrupt model bytes, skips an expired request before native execution and checks
zero live sessions and results after close. Device logs include a compact
`ZYREN_ML_DEVICE_RECEIPT` JSON object. You can also run the app and use its probe
button to view that receipt.

Android requires API 24. iOS requires a deployment target of 16.0, with signing
configured for your team. The hook bundles checksum-pinned ONNX Runtime 1.23.2
libraries and the C++ bridge. See the package README for artifact sources and
platform qualification. A successful build only establishes packaging; a passing
integration test establishes execution on that device. Native allocator bytes
remain unknown.
