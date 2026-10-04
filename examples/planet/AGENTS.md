# Planet builds and provider access

Use `python3 ../../tool/planet.py` from this directory for normal app builds,
launches and provider integration runs. From the workspace root, use
`python3 tool/planet.py`. Put helper options before the Flutter command.

The helper forwards the private provider JSON on every build. Its default is
`~/.config/zyren/planet-provider.json`; `ZYREN_PROVIDER_CONFIG` and
`--provider-config` select another file. Never commit or print credential values.
Do not replace an installed provider-enabled app with a credentialless build
when updating unrelated scenes. Use `--offline` only for an explicitly offline
build. Unit/widget tests that need no provider can use Flutter directly.

Validate changes to provider wiring through
`integration_test/launcher_provider_test.dart`, then restore the normal
`lib/main.dart` launcher with the same private configuration. Report installed
builds separately from live provider, native rendering and foreground checks.
