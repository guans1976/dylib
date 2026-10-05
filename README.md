# V16 Final Request Trace

这是“最终请求快照”版，不再观察 `NSMutableURLRequest` 的中间构造过程，而是钩在 `NSURLSession` 即将创建 task / task resume 的位置。

## 观察位置

- `NSURLSession dataTaskWithRequest:`
- `NSURLSession dataTaskWithRequest:completionHandler:`
- `NSURLSession uploadTaskWithRequest:fromData:`
- `NSURLSession uploadTaskWithRequest:fromData:completionHandler:`
- `NSURLSessionTask resume`

## 输出

`Documents/V16_FinalRequestTrace.log`

重点记录：

- 最终 URL / query
- HTTP method
- 最终 header 列表
- HTTPBody 长度 + SHA256
- HTTPBodyStream 是否存在
- 调用栈
- 当前线程

敏感字段不会记录明文：

- Authorization
- Cookie
- X-Live-Butter2

它们只记录：

- 长度
- SHA256

这样可以比较“手机成功请求”和“PC 请求”结构是否一致，而不导出可复用认证值。

## 推荐操作

1. 注入后冷启动 App。
2. 正常进入首页，让 `/anchor/all` 成功一次。
3. 点一个普通频道一次。
4. 如需要，再进入一次会触发 `/private/getPrivateLimit` 的页面。
5. 导出：

`Documents/V16_FinalRequestTrace.log`

发回日志即可继续分析。

## GitHub 编译

上传本目录全部文件到仓库根目录后：

`Actions -> Build V16 Final Request Trace -> Run workflow`

下载：

`V16FinalRequestTrace-rootless-deb`

如果你的 RootHide Patcher 对 rootless `.deb` 仍报错，把转换页面的具体错误行发回来；不要只给 `error 256`。
