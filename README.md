# V16.5 Decode Feasibility Probe

这版的目的不是导出密钥，而是判断“PC 端复现解码是否值得继续”。

## 它做什么

每次正常调用 `getPrivateLimit` 时记录：

- 原始 opaque response 大小
- 原始 response 的 SHA-256 前 16 位
- App 内部出现 `stream` 对象时对应 JSON Data 大小
- 解码后 JSON 的 SHA-256 前 16 位
- 从 response 到 decoded stream 的耗时
- `flv_pull_url / lll_pull_url / pull_url` 的去-query版本
- 最终 RTC handoff

这样连续测 3~5 次，就能判断：

1. 原始响应是否每次都变化；
2. 解码路径是否稳定；
3. 同一个 App 版本是否始终在同一调用栈上完成解码；
4. `stream` 对象是否每次都稳定产出；
5. PC 端如果实现同样的业务解包，是否有明确输入/输出边界。

## 它不做什么

不会导出：

- AES key / IV
- Authorization / Cookie
- txSecret / txTime
- 完整播放签名
- 任何可重放认证材料

## 测试方法

建议连续进入普通频道 3~5 次，或在多个普通频道之间切换，每次等画面出来后停 5~10 秒。

导出：

- `Documents/V16_5_DecodeFeasibilityProbe.log`
- `Documents/v16_5_decode_feasibility_probe.json`

如果每次都有：
`limit_raw_response -> decoded_stream_sample -> rtc_handoff`

并且调用栈稳定，就说明 PC 复现这条链在工程上是可行方向。
