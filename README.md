# PlayURLLogger V7

Purpose: focused runtime diagnostics for the playback path discovered by V6.1.

## What changed from V6.1
- No global Objective-C class scan.
- Hooks only exact HWLLS/WebRTC selectors observed in the V6.1 runtime log.
- Tries known IJK fallback selectors; missing selectors are logged safely.
- Keeps media URL logging.
- Redacts common authentication query parameters.
- Writes to `Documents/PlayURLLoggerV7.txt`.

## GitHub
Upload:
- `PlayURLLoggerV7.m` to repository root
- `.github/workflows/build-v7.yml` to the same path in the repository

The workflow is path-filtered, so changing V7 will not intentionally trigger this V7 workflow for unrelated files.

## Test
1. Build `Build PlayURLLoggerV7`.
2. Download artifact `PlayURLLoggerV7`.
3. Inject only `PlayURLLoggerV7.dylib` (disable older logger dylibs).
4. Launch app and wait about 8 seconds.
5. Enter one live room and remain for 20-30 seconds.
6. Exit the room.
7. Export `Documents/PlayURLLoggerV7.txt`.

Do not publish logs containing live credentials. V7 redacts common credential names, but review before sharing.
