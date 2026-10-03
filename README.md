# PlayURLLogger V6.1 - Lightweight Runtime Scout

V6.1 fixes the V6 startup stall by doing **no class/method enumeration in the constructor or on the main queue**.

## What changed
- Dedicated log: `Documents/PlayURLLoggerV6_Runtime.txt`
- Immediate marker: `######## PLAYURLLOGGER V6.1 ACTIVE ########`
- Logs its own dylib path, bundle id and pid
- Keeps the proven `NSURL URLWithString:` observer with credential redaction
- Runtime scans only at ~8s, 20s and 40s on a serial utility queue
- dyld image callback does no heavy work; it only coalesces a delayed background rescan
- Only classes matching WebRTC/HWLLS/IJK/FFmpeg/TRTC-related keywords have their methods enumerated
- Method type encodings are recorded to make later hooks safer

## Test
1. Build with GitHub Actions.
2. Inject `PlayURLLoggerV61.dylib` (remove/disable older logger dylibs to avoid mixed logs).
3. Launch app and confirm the home page opens normally.
4. Wait ~10 seconds, enter a live room, stay 20-30 seconds, then exit.
5. Export `Documents/PlayURLLoggerV6_Runtime.txt`.

Do not publish live authentication credentials. V6.1 redacts common secret/token fields in URLs.
