# iPad 支持与 Apple Vision 本地 OCR

日期：2026-11-24
状态：实现完成，平台验证中。

## 用户需求与边界

用户要求在 macOS 改动提交推送后，增加 M1 iPad 支持，并在设备支持时接入本地 OCR。
macOS 提交 `c0feed6` 已推送到 `fork/macos-arm64`，本任务单独记录 iPad 改动。

- 目标设备为 M1 iPad，最低 iPadOS 15；生成独立 iOS/iPadOS 平台工程，不复用 macOS 应用包。
- 支持 EPUB、PDF、单文件 Markdown 导入副本，打开、阅读、保存进度和重开；文件夹 Markdown 仍只读就地读取。
- 支持横竖屏和分屏；复用按可用宽度布局的阅读器，不添加另一套平板阅读器。
- 本地 OCR 使用 Apple Vision `VNRecognizeTextRequest`，PDF 页通过 CoreGraphics 栅格化；支持当前页、范围和整本任务的现有工作流。
- OCR 只在用户主动触发后运行，识别和索引留在设备，不调用云端或自动上传页面。
- 导出通过系统“存储到文件”面板发布应用内生成的文件；图片批注打包为单个 ZIP。
- API key 继续使用系统 Keychain；不新增账号、同步、摄像头扫描或手写识别。
- 本轮不承诺 iPhone、App Store 发布、分发证书或 TestFlight。

## 技术依据与契约

- Apple 的 [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) 支持 iPadOS 13+；当前使用的 [supportedRecognitionLanguages()](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/supportedrecognitionlanguages()) 需要 iPadOS 15+。M1 不构成 OCR 能力限制，实际语言以系统返回列表为准。
- 复用 `pagesage/ocr` 与 `pagesage/pdf_raster`，识别结果标记为 `ios-vision`；文本、行级归一化坐标、置信度和错误码沿用现有契约。
- PDF 图像使用显示方向，白底，最长边和 500 万像素预算；不会一次把整本 PDF 栅格化到内存。
- 文件夹使用 iOS document picker 的原始 URL 创建书签，启动时恢复授权；移除书籍只释放授权，不删除源目录。
- iOS SDK 不支持 `.withSecurityScope` 书签选项，使用默认创建选项和 `.withoutUI` 解析，再显式开始安全作用域访问；授权无法恢复时保留书签并报告目录读取失败，跨重启恢复另做真机验证。
- 不修改数据库 schema、locator 或现有 macOS 书签存储格式。

## 验证计划

| 需求 | 最小证据 | 关键反例 |
| --- | --- | --- |
| 平台与原生注册 | iOS Release 无签名构建，检查设备家族与最低系统 | 插件或通道未注册、错误架构 |
| Vision 与 PDF | iOS 平台集成测试：真实栅格化、英文 OCR、旋转、行框、越界页 | 缺文件、非法语言、失败后下一次请求 |
| 生产装配 | 命名 provider 与 MethodChannel 测试 | iOS 仍落入 Stub、引擎元数据错误 |
| 沙盒导出 | 文件服务与设置导出测试 | 取消、源文件不存在、原文件不变 |
| Markdown 文件夹 | 书签存储与重建恢复测试 | 只读源目录、取消、授权丢失 |
| 阅读与进度 | 离屏平板/分屏组件测试，平台集成测试 | 窄分屏溢出、重开丢页 |
| 其他平台 | macOS 静默构建及受影响命名回归 | 共享 Swift 源码破坏 macOS |

命令输出保存在 `/tmp/pagesage-ipad-*.log`。默认测试并发为 4，不启动可见应用。
## 已完成实现与验证

- 已新增最低 iPadOS 15 的 iOS 工程，限制设备家族为 iPad；iOS Release 无签名构建通过，产物为 `build/ios/iphoneos/Runner.app`（44.1MB）。
- macOS 与 iPadOS 共享 `apple/PagesageNativeChannels.swift`；macOS Release 构建也通过，产物为 `build/macos/Build/Products/Release/pagesage.app`（49.1MB）。
- `flutter analyze --no-pub` 通过；文件选择、目录授权、设置导出、图片 ZIP、OCR MethodChannel 与 iPad 布局定向回归共 50 项通过，日志见 `/tmp/pagesage-ipad-tests.log`；共享 Swift 变更后的构建日志见 `/tmp/pagesage-ipad-ios-build-icons.log` 与 `/tmp/pagesage-ipad-macos-build.log`。
- 完整默认回归 `flutter test --no-pub --concurrency=4`：1193 PASS / 27 SKIP，日志见 `/tmp/pagesage-ipad-full-test.log`。该命令不包含 `integration_test/ipad_native_channels_test.dart`；原生 OCR 集成测试因无设备/runtime 尚未执行。
- iPad 图标已由 `tool/generate_app_icons.py` 生成，所有图标为 RGB、无 Alpha；工程 plist 语法检查和 `git diff --check` 通过。
- 构建后的 `Info.plist` 确认 `UIDeviceFamily = [2]`、`MinimumOSVersion = 15.0`。macOS 分发包及解压后的应用均通过严格签名校验，5 个 Mach-O 文件仅含 arm64，产物见 [macOS 任务](macos-arm64.md)。

当前主机具备 iOS SDK，但没有 iOS Simulator runtime，也没有已连接的 iPad；已执行 Linux 安装脚本，因 macOS 主机不支持 Linux 构建而失败（`"build linux" only supported on Linux hosts.`，日志 `/tmp/pagesage-linux-install-ipad.log`），未更新 Linux 安装。Windows / Android 本轮未验证。
真机签名、安装、文件面板交互、断网 OCR 和重启恢复必须另有实际证据，不能用无签名构建代替。

## 未验证边界

- 未完成 iPad 签名、安装和启动；未在 M1 iPad 上验证中英文识别质量、系统语言列表、CPU/内存耗时。
- 未验证系统文件夹选择器、导出面板、书签在 App 重启后的恢复，也未验证横竖屏、Stage Manager 和真实分屏。
- 未验证 iPhone、App Store 和 TestFlight；M1 硬件本身不限制 Apple Vision OCR，实际可用性仍取决于系统版本、语言支持和识别质量。
