# V16.1 Broker

这是 V16.1 的 Broker 测试版。

功能：
- 保留原来的 `playback_info.json` / `paid_playback_info.json` 导出；
- 捕获 App 正常调用 `getPrivateLimit` 时的 `uid` 作为 `channel_id` 元数据；
- 当 App **正常进入 RTC signaling** 时，把最新合法 playback JSON 放入 Broker cache；
- 在手机前台启动本地 HTTP Broker：`0.0.0.0:8766`；
- `GET /health` 查看状态；
- `POST /refresh` 让 PC 取得当前最新、尚未过期的授权 playback JSON。

它不会伪造签名，也不会复用/导出 Authorization、Cookie 或 App 私有认证头。

重要：这个测试版的 `/refresh` 只能返回 App 已经正常取得的最新播放信息。
如果缓存已经过期，它会要求 App 先正常取得一个新的播放会话；它不会私自重放认证请求。
