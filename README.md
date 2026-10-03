# PlayURLLoggerV4
For authorized diagnostics of an app you are permitted to test.

V4 adds targeted observation of the playback entry points identified during static analysis:
- `HWLLSPlayer setStreamUrl:`
- `IJKFFMoviePlayerController` content URL initializers
- `NSURL URLWithString:` (unfiltered, to expose signaling/API URLs as well as obvious media extensions)

Output: `Documents/PlayURLLoggerV4.txt`

V4 only records URL/argument descriptions and short symbolic call stacks. It does not bypass authentication/DRM or collect authorization headers/cookies.
