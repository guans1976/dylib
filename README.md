# V16.4 GetPrivateLimit Flow Trace

这是干净版，只追踪 `getPrivateLimit` 到正式 HWLLS / WebRTC 播放的链路。

## 目标

确认：

`/OpenAPI/v1/private/getPrivateLimit`
→ 请求需要哪些参数名
→ App 在哪个函数把响应解码成带 `stream` 的对象
→ `HWLLSClientProxy startPlay`
→ `RTCSignalingSender`

## 输出

- `Documents/V16_4_GetPrivateLimitFlowTrace.log`
- `Documents/v16_4_get_private_limit_flow.json`

## 记录内容

### 请求
仅记录：
- method / host / path
- query 参数名
- 每个非敏感参数是否存在、长度、是否纯数字
- header 名以及是否存在/长度

不会记录可复用的 query 值或认证头值。

### 响应
记录：
- HTTP status / mime
- body 大小
- JSON 解码后的 key 结构
- `stream` 对象包含哪些字段
- URL 只保留 scheme/host/path，query 一律 `<redacted>`
- App 调用栈

### 播放
记录：
- `HWLLSClientProxy startPlay:startPlayOptions:` 调用时机和调用栈
- `RTCSignalingSender +sendSignaling:` 调用时机
- 与 getPrivateLimit response / decode 的毫秒级时间差

## 不记录

- Authorization / Cookie
- token / secret / signature
- txSecret / txTime
- X-Live-Butter / knockknock
- ICE pwd / fingerprint / 完整 SDP
- 可重放认证材料

## 测试

普通频道优先：

1. 冷启动 App
2. 点一个普通频道
3. 等正式画面出来
4. 停留 10~15 秒
5. 导出两个文件

如果普通频道有多次自动刷新，也可以多停留一会儿，这样能看清 `getPrivateLimit` 是否会周期性签发新地址。
