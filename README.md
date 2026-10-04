# PaidPreview V3.4 — V20 Diagnostic Exporter

用途：把 V3.3 已确认的“双通道实际调用”进一步整理成可对照 V20 的诊断 JSON。

这版会记录：
- 预览 HTTP-FLV URL（query 脱敏）
- WebRTC stream URL（query 脱敏）
- HLLL / HWLLS 关键调用时序
- signaling type / host / port / domain / target domain
- PeerConnection 是否创建
- local/remote SDP 的**结构摘要**
- DNS 结果中的 host IP / port（若 Objective-C 对象暴露这些属性）
- start / stop 时间

安全处理：
- 不导出完整 SDP
- 不导出 ICE ufrag / ICE pwd
- 不导出 DTLS fingerprint
- 不导出 candidates
- 不导出 URL 查询参数中的授权 token / txSecret

输出：
- Documents/PaidPreviewV3_4_V20DiagnosticExporter.log
- Documents/preview_v3_4_v20_diagnostic.json

建议：
1. 只跑一次收费预览页，等待预览自然结束。
2. 导出两份文件。
3. 再单独跑一次普通正常播放页，导出第二组文件。
4. 用两组 JSON 做字段级对照。
