# V15 手机导出 → 电脑播放与录制

本包是首次端到端联调版本，尚未使用真实有效 JSON 完成播放验证，不能保证当前平台信令接受电脑重新协商。

1. 把 V15PlaybackExport.m 和 .github/workflows/build-v15.yml 放入已有构建仓库，提交后启动 Build V15 Playback Export。下载产物，用此前的方法注入 IPA；移除旧观察 dylib。
2. 手机上进入直播并等几秒，导出 App Documents/playback_info.json。文件必须 status=ready 并包含 request。只有 waiting 的 V11/V15 文件不能录制。
3. Windows 安装 Python 3.11 或 3.12（含 py 启动器），将 JSON 放到本包目录，双击 start_windows.bat。
4. 浏览器进入 http://127.0.0.1:8765，点击“开始播放并录制”。浏览器第一次可能需要点击视频播放按钮以允许声音。录像保存在 recordings；点击“停止并保存”后再关闭程序。
5. macOS/Linux：python3 -m venv .venv；激活环境，pip install -r requirements.txt；python desktop.py playback_info.json。

手机仅捕获 NSURLSession 中包含 SDP 的 JSON 请求，不修改手机请求或响应。电脑保留请求模板，用电脑自己生成的 SDP 替换手机 offer，向实际信令地址发起新会话；不会复用手机 ICE 密钥或证书。未构造或猜测其他协议 URL。

限制：非 JSON/HTTPBodyStream/其他网络栈不会被此导出器捕获；模板中的业务签名、时间戳、会话标识可能不能重复使用；未实现平台专属签名重算、心跳、重连或 TURN 配置。HTTP 拒绝或缺少 answer SDP 时会明确报错。只适用于实际请求格式兼容的流，不能把 ready 当成播放成功。手机可先保持运行测试，再退出验证是否独立录制。JSON 授权过期需重新导出。

首次错误请提供：status 是 waiting 还是 ready，以及电脑页面错误或控制台连接错误。本程序不把完整信令响应打印到控制台。MP4 正常停止才会写完索引；强杀可能损坏。
