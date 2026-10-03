# V16：华为 WebRTC JSON 导出及电脑播放录制

修复 V15 只得到 waiting：直接 Hook WebRTC.framework 的 +[RTCSignalingSender sendSignaling:]，读取真实 RTCSignalingSenderParam。SDK 经原生 C++ 信令发送，不依赖 NSURLSession。

## 手机
1. 上传 V16PlaybackExport.m 和 .github/workflows/build-v16.yml 到已有构建仓库根目录（不要上传外层 v16-package 文件夹）。提交后，在 Actions 手动运行 Build V16 Playback Export。
2. 下载 V16PlaybackExport.dylib，使用此前注入方法；移除旧导出/观察 dylib，避免互相覆盖 JSON。
3. 完全退出 App 后重开，重新进入直播，等 3 秒。导出 Documents/playback_info.json 和 Documents/V16_PlaybackExport.log。
4. JSON 必须 schema=hwlls-playback-v16、status=ready，并含 request、stream_url。waiting 表示尚未进入信令入口；hook_missing/abi_mismatch/incomplete 会明确标识导出失败。

## Windows
使用 Python 3.12 x64（可与现有 3.14 共存，保留 py 启动器）。把新的 playback_info.json 放到 desktop.py 所在目录，双击 start_windows.bat。
等终端显示服务地址后，用 Chrome/Edge 打开 http://127.0.0.1:8765，点击“开始播放并录制”。确认画面及声音；浏览器可能要求手动点击播放才能有声音。结束时点“停止并保存”，再关终端；录像在 recordings。
也可手动执行：py -3.12 -m venv .venv；.venv\Scripts\python.exe -m pip install -r requirements.txt；.venv\Scripts\python.exe desktop.py playback_info.json。

## 联调范围
已从二进制确认 HTTP/HTTPS 端点 /webrtc/v1/pullstream，POST JSON 的 streamurl 与 localsdp:{type:"offer",sdp:...} 格式，HTTP 用 80、HTTPS 用 443。响应使用 remotesdp。电脑生成自己的 offer / ICE 密钥 / DTLS 证书，替换导出的 SDP，从服务器新建独立播放会话；原手机 SDP 只用于识别替换位置，不直接复用它接收媒体。

native_signaling_type=0 为 HTTP、1 为 HTTPS、2 为 UDP mini-SDP。若手机原生使用 UDP，导出器保留其真实参数，生成已确认的 SDK HTTPS 请求格式，并标记 requires_http_transport_test=true：服务器是否允许该流使用 HTTPS 尚需实测；这不是手机实际发送的 HTTP 请求。ready 仅指参数齐全，不能证明电脑已收到视频。

当前没有真实有效流可做线上验证，不能承诺 JSON 必然播放。手机端 Apple SDK 编译需在 Actions 完成；电脑代码验证结果见 VALIDATION.md。若服务器拒绝、鉴权过期、仅支持 UDP、音频编码不兼容或网络无法直连，需要按具体结果继续适配。尚未实现平台专属心跳、断线重连和 UDP mini-SDP。电脑端请先保持手机运行测试，再关闭手机验证独立性。

本包不附虚构的可播放 JSON：运行时地址和授权必须来自当前手机直播。V11/V15 的 waiting JSON 无法填充为真实请求。
