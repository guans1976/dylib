# V10 Object Inspector

Narrow diagnostic build based on the V9 trace.

It inspects only objects already participating in the app's normal playback path:
- HWLLSStartPlayOptions
- RTCDnsResult
- RTCSignalingSdpResp

The inspector enumerates Objective-C properties on those objects and calls only zero-argument property getters. It logs scalar values plus NSString/NSNumber values. Complex objects are logged by class name only.

Privacy filters omit/redact properties whose names suggest SDP, tokens, secrets, ICE credentials, fingerprints, candidates, IP/address/host data.

## Test
1. Inject only PlayURLLoggerV10.dylib.
2. Launch and wait 10 seconds.
3. Enter one live room, remain 20–30 seconds, then exit.
4. Export `Documents/PlayURLLoggerV10_Objects.txt`.

Do not publish raw logs before reviewing them.
