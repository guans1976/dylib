# V12 HWLLS Downgrade Inspector

Focused diagnostic build after V11 observed no standard media endpoint.

It:
- hooks the exact `HWLLSClient` / `HWLLSClientProxy` start path already confirmed in prior runtime work;
- logs the relevant runtime method names/type encodings;
- inspects only URL/downgrade/policy/domain/stream-related properties;
- redacts complete URLs, query strings and obvious authorization values.

It does **not** force downgrade, synthesize a URL, alter authentication, or change playback decisions.

## Test
1. Build/inject V12.
2. Start the app and enter one normally playable live stream.
3. Let it play ~15 seconds.
4. Exit the live stream normally.
5. Retrieve `Documents/V12_HWLLS_DowngradeInspector.log`.

The method inventory is especially important: it tells us the exact selectors exposed by this particular HWLLSPlayer build, rather than assuming the public SDK version matches it.
