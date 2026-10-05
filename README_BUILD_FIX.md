# V16.1 Broker.1 Build Fix

修复 Xcode/clang 编译错误：

`property 'lengthOfBytesUsingEncoding' not found on object of type 'NSString *'`

错误写法：
`[s substringFromIndex:...].lengthOfBytesUsingEncoding:NSUTF8StringEncoding`

正确 Objective-C 消息发送：
`[[s substringFromIndex:...] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]`

其余逻辑未改。
