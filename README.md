# V14.1 播放器路线观测版

修复：协议分类辅助函数改名为 V14ProtocolLabel，消除与 Objective-C Protocol 类型的命名冲突。源码、工作流和 dylib 文件名继续使用 V14，直接覆盖原文件即可。

基于 V13 的单文件 Objective-C dylib 与 GitHub Actions 构建方式，按原 IPA 的 ARM64 反汇编结果收窄观测位置。本版不强制降级、不更改地址、不绕过鉴权；作用是验证正常或失败播放时实际进入哪条播放器路径。

## 构建及使用

1. 将本目录完整上传到 GitHub 仓库，包含 `.github/workflows/build-v14.yml`。
2. Actions 中手动运行 Build V14 Player Route Trace，下载生成的 dylib。
3. 使用此前相同的注入方式载入 V14；先移除 V7–V13 等旧观测 dylib，避免重复 hook。
4. 启动 App，进入直播间，等待 20–30 秒。存在失败直播间时，再测一次失败场景。
5. 读取 App Documents 下的 `V14_PlayerRouteTrace.log`，退出前等待约两秒让异步日志落盘。

当前环境没有 Apple iPhoneOS SDK，交付的是源码与构建工作流，尚未完成 iOS 编译或真机验证。

## 读日志

- HUAWEI_INIT：初始化华为播放器，显示 delegate 的类名。
- HUAWEI_START：进入华为播放路径，仅显示协议类别。
- HUAWEI_START_RETURN：同步启动返回码；0 不代表首帧播放成功。
- IJK_PREPARE：进入 IJK prepareToPlay，仅显示协议类别，不代表首帧成功。
- SIGNAL_RESULT：服务端错误码；601 对应本次查明的业务降级错误。
- ERROR_BRANCH：reportError=YES 表示错误上报分支；NO 表示 SDK 继续请求分支。
- SDK_ERROR / APP_ERROR：错误向 SDK client 和主 App 传递；500000021 是业务降级错误。
- APP_ERROR_RETURN：App 错误回调已经返回；若之后出现 IJK_PREPARE，才有进入 IJK 播放准备路径的证据。
- DNS_FALLBACK_FLAG：域名解析回退标志；不能作为播放协议切换证据。
- ABI_SKIP：方法签名与本版预期不符，已跳过；不能把缺失事件理解成未调用。
- MISS：等待最多约 20 秒仍未找到类或方法。

## 已验证的静态逻辑

UserModel.lllPullUrl 非空时优先使用它，必要时加 webrtc://；为空时选 pullUrl。最终按 webrtc:// 前缀选择 HLLLManager/HWLLSClient 或 IJKFFMoviePlayerController。

StreamPlayerManager.onError:errorCode:errorMsg: 仅保存 lastStreamError。已追踪的错误说明读取函数传递提示文字，没有直接调用备用播放器。

## 隐私与稳定性

不记录原始 URL、域名、地址路径、查询参数、错误说明、响应对象内容或对象 description；只记录固定事件名、数值错误码、协议分类、类名和布尔值。因此不输出 txSecret、token、ICE 密钥、指纹或 IP。

不挂钩裸 Swift 地址，不使用 ASLR 地址补丁。方法替换前校验返回值和参数 ABI；继承方法通过子类添加实现避免修改父类。最多写入 2000 条日志，不进行全局网络观测。
