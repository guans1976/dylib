
# PaidPreview V3.2 — V20 Compare Trace

目标：只做“通道对照”，不修改播放逻辑，不延长预览，不伪造授权。

本版同时保留 V3.1 的 IJK/HTTP-FLV 观察点，并增加：
- NSURLSession 请求 URL 的 host/path 级观察（query 自动脱敏）
- 运行时枚举 `HWLLS` / `HLLL` / `WebRTC` / `RTC` / `IJK` 相关类与方法
- 自动分类：
  - `preview_http_flv_only`
  - `v20_webrtc_like`
  - `dual_path_evidence`
  - `unknown`

输出：
- `/var/mobile/Documents/PaidPreviewV3_2_V20Compare.log`
- `/var/mobile/Documents/preview_v3_2_compare.json`

## GitHub Actions
把整个目录上传到 GitHub 仓库，Actions -> `Build PaidPreviewV3.2 V20 Compare` -> Run workflow。
产物：`PaidPreviewV3_2_V20Compare.dylib`

## 运行测试建议
1. 注入 dylib 后启动 App。
2. 进入收费预览页并播放至少 20~30 秒。
3. 不要切到其它直播，避免日志混杂。
4. 导出上面两个文件。
5. PC 端：
   `python pc/compare_trace.py analyze preview_v3_2_compare.json`

## 这版重点
不是绕过“一分钟”，而是确认预览页是否还同时存在 V20 的 WebRTC/HWLLS 证据。
