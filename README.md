# V9 Playback Decision Trace
V9 uses the exact Objective-C ABIs observed in the V8 log.

Focus:
- `startPlay:startPlayOptions:` return value + options object
- signaling request/result objects
- `playNeedReplayWithErrorCode:` decision
- `dealErrorCode:` input
- downgrade YES/NO transitions
- IJK/HLS/FLV/RTMP takeover

It does not alter decisions or force fallback.

Test:
1. Inject only V9.
2. Launch and wait 10 seconds.
3. Enter a live room for 20–30 seconds and exit.
4. Export `Documents/PlayURLLoggerV9_Decision.txt`.
5. A second test with an ordinary temporary network interruption can reveal the app's own recovery path; do not manipulate servers or authentication.

Review logs before sharing. Credential-like URL fields are redacted.
