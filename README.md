# PlayURLLogger V8 — Fallback Scout

V8 focuses on the playback decision path rather than dumping WebRTC SDP.

It observes:
- HWLLS playback entry / scheduler calls
- signaling result objects
- error/replay/downgrade decisions
- IJK takeover
- WebRTC/HLS/FLV/RTMP media URLs

Safety/stability changes:
- scans only HWLLS/IJK classes once, after an 8-second delay
- checks Objective-C runtime type encodings before installing each hook
- ABI mismatches are logged as `ABI-SKIP` rather than hooked
- common credential fields are redacted
- does not intentionally dump full SDP/ICE credentials

## Upload
- `PlayURLLoggerV8.m` -> repository root
- `.github/workflows/build-v8.yml` -> `.github/workflows/`

## Test
1. Build `Build PlayURLLoggerV8`.
2. Download artifact `PlayURLLoggerV8`.
3. Inject only `PlayURLLoggerV8.dylib`; disable V6/V6.1/V7.
4. Launch the app and wait at least 10 seconds.
5. Enter a live room and remain 20–30 seconds.
6. Exit the room.
7. If practical, repeat once with a normal network interruption/recovery to observe the app's own fallback behavior.
8. Export `Documents/PlayURLLoggerV8_Fallback.txt`.

Do not publish logs until you have reviewed them for credentials or network identifiers.
