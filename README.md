# Paid Preview V1

这是一套只用于“收费页当前授权试看流”的独立测试链，不改普通直播 V16/V20。

## 手机插件
`PaidPreviewV1.m` 只观察 IJK：
- `IJKFFMoviePlayerController initWithContentURL...`
- `IJKMediaUrlOpenData setUrl:`

仅当 URL 是 `api.qituoc.com/preview/.../*.flv` 时写入：
`Documents/preview_playback.json`

日志 `PaidPreviewV1.log` 只记录脱敏后的 URL 形状；JSON 为了让电脑端测试播放，会保存 App 当前实际收到的完整试看 URL。
插件不会构造 URL、刷新 URL、修改试看时长或改变付费状态。

## GitHub Actions
把 `PaidPreviewV1.m` 和 `.github/workflows/build-paid-preview-v1.yml` 放入仓库后运行 workflow，下载 `PaidPreviewV1.dylib`。

## 电脑端
1. 安装 FFmpeg，并确保命令行可执行 `ffmpeg` 和 `ffplay`。
2. 手机进入收费页并开始正常试看。
3. 导出最新 `preview_playback.json` 到 `PC` 文件夹。
4. 双击 `start_windows.bat`。
5. 浏览器会打开 `http://127.0.0.1:8766`。
6. 点“开始播放并录制”。

播放器只使用 JSON 中当前授权的 HTTP-FLV 地址；不会刷新、推导或延长该地址。地址过期后请回到 App 正常重新进入试看并重新导出 JSON。
