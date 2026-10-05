# V16 Request Construction Trace

用途：观察 App 在真正发出请求之前，如何构造 `NSMutableURLRequest`。

重点关注：
- `/OpenAPI/v1/anchor/all`
- `/OpenAPI/v1/private/getPrivateLimit`
- `api.qituoc.com`

Hook：
- `setValue:forHTTPHeaderField:`
- `addValue:forHTTPHeaderField:`
- `setAllHTTPHeaderFields:`
- `setHTTPBody:`
- `setURL:`
- `setHTTPMethod:`

输出：

`Documents/V16_RequestConstructionTrace.log`

每条记录包含：
- method
- URL
- body 长度
- body SHA-256
- header 名称
- 普通 header 值
- Authorization / Cookie / X-Live-Butter2 只记录长度，不记录实际值
- 调用栈

## 目的

用来判断：
- `X-Live-Butter2` 在哪一层写入
- 是否有其它 header 在发出前被动态补入
- body 是否在最后阶段被替换
- 哪些 App 函数参与构造 `/anchor/all`

## 边界

这个版本不会：
- 导出 Bearer/Cookie/Butter2 明文
- 生成或伪造认证字段
- 绕过收费/权限
- 修改请求结果

它只是观察请求构造过程。

## 建议测试步骤

1. 注入后冷启动 App
2. 正常登录
3. 打开频道列表一次
4. 点进一个普通频道一次
5. 导出 `Documents/V16_RequestConstructionTrace.log`
6. 把日志发回来分析

