
# PaidPreview V3.2.1 — Log Fix

修正点：
- 不再写死 `/var/mobile/Documents`
- 自动使用 App 自己的 `Documents`
- Documents 不可写时自动回退到 `NSTemporaryDirectory()`
- 同时输出 `NSLog + stderr`
- 所有文件创建/写入失败都会打印错误
- JSON 内写入实际 log/json 路径
- GitHub Actions 改为仅手动触发，避免上传文件时连续编译

正常情况下输出位于 App 沙盒：
- `Documents/PaidPreviewV3_2_1_V20Compare.log`
- `Documents/preview_v3_2_1_compare.json`

如果 Documents 不可写，则在 App tmp 目录：
- `tmp/PaidPreviewV3_2_1_V20Compare.log`
- `tmp/preview_v3_2_1_compare.json`

测试：
1. 编译并注入。
2. 只要启动 App，哪怕还没播放，也应该立即产生 log。
3. log 首行应包含：
   `PaidPreviewV3.2.1 V20 Compare Trace active`
4. 如果没有文件，查看设备控制台，搜索 `[V3.2.1]`，会显示实际路径或写入错误。
