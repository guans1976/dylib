# V3.5 Channel Info Trace

静态分析确认：
- App 内使用 Alamofire。
- 主程序包含 `/private/previewPrivateRoom`。
- 主程序包含 `room_id`、`preview_time` 等字段字符串。

本版用途：
- 记录发往 `qituoc.com` 的请求 URL、method、非敏感 headers、JSON body。
- 记录服务器返回的 JSON 响应。
- 同时兼容 NSURLSession completion-handler 路径和 Alamofire delegate 路径。
- 自动脱敏 token / secret / signature / cookie / authorization / password / userSig / txSecret / session/device/contact 等字段。
- 单个 response 最多缓存 2 MB。

输出：
- `Documents/PaidPreviewV3_5_ChannelInfoTrace.log`
- `Documents/preview_v3_5_channel_info.json`

测试建议：
1. 启动 App。
2. 打开频道列表并上下滚动，让频道数据加载完整。
3. 分别点击几个免费/普通/收费频道。
4. 对收费频道触发一次正常预览。
5. 导出 log 和 json。

目标不是绕过付费，而是确认：
- 频道列表接口是什么；
- 每个频道服务端返回了哪些字段；
- `/private/previewPrivateRoom` 的真实 request body / response schema；
- 哪个业务字段与 preview FLV / WebRTC stream name 对应。
