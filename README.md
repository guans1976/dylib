# V11 Endpoint Observer + PC Recorder

Purpose: observe a standard HLS / HTTP-FLV / RTMP endpoint that the app/SDK itself actually creates during its normal authorized playback/fallback path, write it to `Documents/playback_info.json`, then let a PC-side watcher hand that endpoint to FFmpeg.

V11 does **not** synthesize an endpoint, alter authentication, force downgrade, or replay WebRTC/ICE credentials.

## Phone
Build `V11EndpointObserver.dylib` with GitHub Actions and inject only this observer for the test.

Files:
- `Documents/playback_info.json`
- `Documents/V11_EndpointObserver.log`

If the session remains WebRTC-only, the JSON remains `waiting`; that is a valid result.

## PC
Install FFmpeg and Python 3. Copy or otherwise sync `playback_info.json` from your own phone to the PC, then run:

`python pc_recorder.py playback_info.json -o recording.mkv`

The JSON may contain a temporary authorized playback URL. Keep it private and do not publish it.

The first version intentionally does not implement phone-to-PC networking; it validates endpoint observation and recording first.
