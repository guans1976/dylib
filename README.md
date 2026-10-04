# V3.4.1 compile fix

修复 GitHub Actions 编译错误：

- 增加 `#import <objc/message.h>`
- `objc_msgSend` 改为显式函数指针调用，避免 C99 implicit function declaration 错误
- 其余 V3.4 诊断逻辑保持不变

输出：
- `Documents/PaidPreviewV3_4_1_V20DiagnosticExporter.log`
- `Documents/preview_v3_4_1_v20_diagnostic.json`
