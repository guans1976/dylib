# V13 HWLLS Signaling / Downgrade Trace

Focused observer based on V12 runtime results.

Hooks only:
- `setIsNeedDowngrade:`
- `playSignalingRequest`
- `playRequestResultDoingWithSdpResp:`
- `getDomain`
- `setStreamUrl:`
- `streamUrl`

It does not force downgrade, modify playback, synthesize media URLs, or alter authorization.

Sensitive URLs, query strings, ICE data, fingerprints, signatures and tokens are redacted. It records protocol classification instead.

## Test
1. Inject/build V13.
2. Launch app and enter one normally playable live stream.
3. Let it play 15–30 seconds.
4. Exit normally.
5. Retrieve:
   `Documents/V13_HWLLS_SignalingDowngradeTrace.log`

Useful observations:
- whether `setIsNeedDowngrade:YES` ever occurs;
- whether signaling is invoked again after that transition;
- response object field names/codes around the transition;
- whether `streamUrl` protocol changes;
- which domain path is consulted.

If the normal session never downgrades, that is still a definitive result and the next step should be static XREF/disassembly of the downgrade branch rather than forcing it.
