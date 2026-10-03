# PlayURLLogger V5

Diagnostic logger for an authorized iOS app test environment.

Logs to `Documents/PlayURLLoggerV5.txt`.

V5 observes:
- NSURL creation (credentials redacted)
- HWLLSPlayer `setStreamUrl:`
- IJK player content URLs / fallback candidates
- RTCPeerConnection remote/local SDP summaries
- ICE candidate type/protocol summaries
- WebRTC configuration changes
- `[PC-CANDIDATE]` markers for HLS/FLV/RTMP URLs

V5 intentionally does not dump reusable authorization headers, cookies, full ICE addresses, or SDP ICE credentials.
