# PlayURLLoggerV3
For authorized app diagnostics. When a media URL is created through NSURL,
V3 records the URL and a short symbolic call stack to identify the player/framework
that handed the URL to Foundation. It does not decrypt media, bypass DRM/authentication,
or collect cookies/authorization headers.

Output: Documents/PlayURLLoggerV3.txt
