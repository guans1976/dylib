# V16.3 Stream Origin Trace

这版不是继续扩大抓包，而是专门追踪：

`业务接口响应 -> App 内部解析/解码 -> 第一次拿到播放 URL -> RTCSignalingSender`

## 为什么普通频道也可以直接点

V16.2 已经证明正式播放最后都会落到同一个 `RTCSignalingSender +sendSignaling:`。
所以 V16.3 同时覆盖普通频道和 private 频道。普通频道通常更简单，反而更适合先把“播放 URL 从哪里来的”找出来。

## 新增观察点

1. 继续记录 qituoc.com 的 live / room / private / play / stream 请求；
2. 记录目标接口响应后 2 秒内发生的 `NSJSONSerialization JSONObjectWithData`；
3. 只在目标响应后 3 秒内，观察 NSDictionary 对这些 key 的读取：
   - streamUrl / stream_url / stream
   - playUrl / play_url
   - pullUrl / pull_url
   - liveUrl / live_url
   - url
4. 一旦这些 key 对应的 value 看起来像播放 URL，记录：
   - key 名
   - 去 query 后的 URL
   - NSDictionary concrete class
   - 到 checkUserMoney / getPrivateLimit / checkPrivateCharge 的时间差
   - 12 层调用栈
5. RTC handoff 同样记录调用栈和时间差。

## 不记录
- Authorization / Cookie
- token / secret / signature
- txSecret / txTime
- X-Live-Butter / knockknock
- ICE pwd / DTLS fingerprint / 完整 SDP
- 可重放认证材料

## 测试建议

先测试普通频道：
1. 冷启动 App；
2. 进入普通频道；
3. 等正式画面出来；
4. 停留 10~20 秒；
5. 导出：
   - `Documents/V16_3_StreamOriginTrace.log`
   - `Documents/v16_3_stream_origin_trace.json`

然后如果方便，再测试一次 private/付费频道。

## 我下一步会重点看
- `dict_media_url_access`
- `json_decode_near_target_response`
- `rtc_handoff`

如果 `dict_media_url_access` 在 `rtc_handoff` 前几毫秒出现，调用栈通常就能直接指向业务层哪个方法/类把正式 URL 取出来。
