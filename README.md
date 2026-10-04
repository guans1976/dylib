# V16.2 Paid Flow Trace

目标：把“付费确认 -> 后台返回播放信息 -> RTCSignalingSender”的业务链按时间顺序抓清楚。

## 只记录这些
- qituoc.com 下 path 含 private / room / live / anchor / play / stream / preview 的请求
- method / host / path / 是否带 query
- HTTP status / mime / response bytes
- JSON 顶层字段名和少量业务字段
- 如果响应或字段里出现 URL，只保留 scheme/host/path，query 统一 `<redacted>`
- 最终 RTCSignalingSender 收到的 streamUrl 也只记录去掉 query 的版本

## 明确不记录
- Authorization / Cookie
- token / secret / signature / sign / key
- txSecret / txTime
- X-Live-Butter 等自定义认证头
- ICE pwd / DTLS fingerprint / 完整 SDP
- 可重放的授权材料

## 输出
- `Documents/V16_2_PaidFlowTrace.log`
- `Documents/v16_2_paid_flow_trace.json`

## 测试流程
1. 启动 App
2. 进入一个需要付费确认的房间
3. 点击“付费观看”
4. 等正式画面出来
5. 再停留 10~20 秒
6. 导出上面两个文件

重点看事件顺序：
`http_request`
→ `http_response` / `http_response_delegate`
→ ...
→ `rtc_handoff`

如果中间某个 response 从 opaque 变成了 JSON，或者某一步首次出现 `stream_url / streamurl / play_url`，
基本就找到“签发/下发正式播放地址”的后台接口了。
