# V16.6 Decode Boundary Probe

目标：确认 `getPrivateLimit` 原始响应到 JSON 之间的边界是否稳定。

## 记录的边界

- `boundary_raw_response`
  - 原始 opaque response 大小 + SHA256 前16位
- `boundary_base64_string`
  - 如果 App 走 `NSData initWithBase64EncodedString:options:`，记录输入长度和输出长度/指纹
- `boundary_base64_data`
  - 如果 App 走 `NSData initWithBase64EncodedData:options:`，记录输入/输出长度和指纹
- `boundary_json_output`
  - 出现带 `stream` 的 JSON 时，记录 JSON Data 大小/指纹和调用栈
- `boundary_rtc_handoff`
  - 最终正式 WebRTC 交接

## 重要说明

这版只记录：
- 长度
- SHA256 前16位
- 调用栈
- 去掉 query 的播放 URL

不会记录：
- AES key
- IV
- Authorization / Cookie
- txSecret / txTime
- 完整签名参数
- 完整解密明文

## 测试

连续进入 3~5 个普通频道，每个停留 5~10 秒。

导出：
- `Documents/V16_6_DecodeBoundaryProbe.log`
- `Documents/v16_6_decode_boundary_probe.json`

如果日志出现：
`boundary_raw_response -> boundary_base64_* -> boundary_json_output`
说明 Base64 边界被直接命中。

如果没有 `boundary_base64_*`，但仍稳定出现：
`boundary_raw_response -> boundary_json_output`
说明 Base64 可能走纯 Swift/CryptoSwift 内部路径，下一步再按静态地址/Swift 符号做更窄的探针。
