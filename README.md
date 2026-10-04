# PaidPreview V2 Trace

目标：尽可能观察收费预览 HTTP-FLV 从 IJK 初始化到 Foundation 网络层的请求结构，用于分析 PC 裸请求为何返回 409/502。

输出：
- `Documents/PaidPreviewV2Trace.log`
- `Documents/preview_trace.json`

抓取：
- IJK initializer / `IJKMediaUrlOpenData setUrl:`
- NSURLSession request method、普通 headers、HTTP body 长度
- NSURLConnection 请求（若使用）
- 事件顺序与时间

隐私/安全：
- `/preview/` 的不透明路径在 trace/log 中脱敏。
- Cookie、Authorization、token、secret、signature、session、device、credential、fingerprint 等值不落盘，只记录长度和 SHA-256 前 8 字节摘要。
- 不修改请求、不强制播放、不延长试看、不重放认证材料。

使用：注入 dylib，重新进入一次收费预览并正常播放约 10–20 秒，然后导出两个文件给我分析。
