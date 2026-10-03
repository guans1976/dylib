# PlayURLLogger V6 — Runtime Scout

Diagnostic build for discovering the actual runtime classes, selectors, and loaded images involved in the app's playback path.

## Output
`Documents/PlayURLLoggerV6.txt`

## What it records
- Interesting loaded Mach-O images/frameworks
- Runtime Objective-C classes whose names relate to WebRTC/HWLLS/player/signaling/SDP/ICE/IJK/FFmpeg/TRTC
- Interesting instance/class selectors on those classes
- NSURL strings, with common credentials redacted
- Re-scans for 60 seconds and reacts to newly loaded images

V6 intentionally does not dump cookies, authorization headers, or reusable authentication secrets.
