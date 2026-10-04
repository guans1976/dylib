# V16.1 Paid Playback Extension

基于原 `V16PlaybackExport.m` 扩展，原普通 V20 输出逻辑保留。

## 行为

- 普通播放：仍然写 `Documents/playback_info.json`
- 当检测到 App 发起 `/private/checkPrivateCharge` 后：
  - 设置 120 秒的 `paidPending` 标记
  - 如果随后 App 自己真正进入 `RTCSignalingSender +sendSignaling:`
  - 同一份 `hwlls-playback-v16` 兼容记录会额外写入：
    `Documents/paid_playback_info.json`
- 不调用收费接口
- 不伪造收费成功
- 不修改 stream URL
- 不生成 txSecret
- 不阻止 App 原来的网络请求或播放流程

## 输出文件

- `playback_info.json`：原 V16/V20 路径
- `paid_playback_info.json`：付费按钮之后、App 已实际进入 RTC signaling 时的镜像输出
- `V16_1_PaidPlaybackExport.log`：诊断日志

## 测试步骤

1. 编译并注入 `V16_1PaidPlaybackExport.dylib`
2. 启动 App
3. 先测试一个普通频道，确认 `playback_info.json` 正常产生
4. 再进入付费频道并正常点击“付费观看”
5. 如果 App 正常进入正式 WebRTC，会产生 `paid_playback_info.json`
6. 将它交给前面做的 V20.3 PC 扩展播放器

日志中关键字：
- `PAID_MARK`：检测到了 `checkPrivateCharge`
- `SEND ... paidFresh=1`：收费标记后发生 RTC signaling
- `PAID_EXPORT ready`：成功生成 PC 可读 JSON
