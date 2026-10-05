# V16 Final Request Trace — dylib 版

这版恢复到你之前一直用的方式：GitHub Actions 直接产出：

- `V16FinalRequestTrace.dylib`
- `V16FinalRequestTrace.plist`

不再要求先生成 `.deb`。

## GitHub 编译

把本目录文件上传到仓库根目录后：

1. 打开 GitHub -> Actions
2. 选择 `Build V16 Final Request Trace Dylib`
3. 点 `Run workflow`
4. 编译完成后下载 Artifact：
   `V16FinalRequestTrace-dylib`

解压后就是：

`V16FinalRequestTrace.dylib`

## 作用

插件只做最终请求结构观察：

- NSURLSession dataTaskWithRequest
- uploadTaskWithRequest
- NSURLSessionTask resume

日志：

`Documents/V16_FinalRequestTrace.log`

敏感字段 `Authorization / Cookie / X-Live-Butter2` 不记录明文，只记录长度和 SHA256。
