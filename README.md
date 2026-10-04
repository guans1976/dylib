# PaidPreview V3.1 Native Trace

基于 V20 的方法论：不猜 PC 参数，先寻找 IJK/FFmpeg 最靠近实际媒体打开的位置。

本版：
- 展开 `IJKFFMoviePlayerController ...withOptions:` 的 options 对象；
- 记录 IJK URL-open 对象的可读属性；
- 枚举运行时中 IJK / FFmpeg / FFIO / URL-open 相关 Objective-C 类和方法，重点列出 url/options/header/open/http/format；
- 修复 V2 JSON 一直显示 waiting 的问题。

输出：
- `Documents/PaidPreviewV3_1NativeTrace.log`
- `Documents/preview_v3_trace.json`

认证类字段不会写原始值，只保留存在性/长度。插件不修改请求和播放状态。

测试：注入后打开收费预览并正常播放约 15 秒，再退出。把两个输出文件发回分析。
