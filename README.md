# PlayURLLogger

A minimal arm64 iOS dylib for authorized debugging of an app you control or are permitted to inspect.

It observes `NSURL URLWithString:` and records URLs containing:

- HTTP / HTTPS
- `.m3u8`
- `.flv`
- RTMP / RTMPS
- WebRTC scheme URLs

## Build

1. Upload all files/folders in this project to the root of your GitHub repository.
2. Open **Actions**.
3. Select **Build PlayURLLogger**.
4. Choose **Run workflow**.
5. When the run finishes, download the `PlayURLLogger` artifact.
6. Unzip it to obtain `PlayURLLogger.dylib`.

## TrollFools

Inject `PlayURLLogger.dylib` into the target app, then launch the app and open a stream.

The log is written inside that app's sandbox at:

`Documents/PlayURLLogger.txt`

Use Filza or another authorized sandbox browser to retrieve it.

## Note

This first build intentionally hooks only a high-level Foundation URL constructor. If the player creates media connections entirely in native FFmpeg/WebRTC code, the log may not contain the media URL; that result tells us the next layer to inspect.
