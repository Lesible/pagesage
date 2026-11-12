# macOS arm64 分发说明

更新：2026-11-13

PageSage 的 macOS 构建面向 Apple Silicon（arm64），最低系统版本为 macOS 12。
首个切片不提供 Intel 或 universal 包，也不包含 Mac App Store、Developer ID 签名
与公证。构建、打包、自动测试与本机真实窗口阅读闭环已完成；外部用户目录授权、
导出面板和跨机器 Gatekeeper 行为仍需人工验收。

## 产物

发布产物为：

```text
pagesage-<version>-macos-arm64.zip
pagesage-<version>-macos-arm64.zip.sha256
```

压缩包内部结构：

```text
pagesage/
  pagesage.app/
  LICENSE
  NOTICE
  THIRD_PARTY_LICENSES.md
  LICENSES/
```

`pagesage.app` 是完整应用包，必须整体保留；不要只复制其中的可执行文件。
打包脚本会保留 framework 内的符号链接，并检查应用包内每个 Mach-O 文件都只含
arm64，拒绝 x86_64 或 universal 产物。

## 安装与首次运行

1. 下载 ZIP 与 SHA-256 校验和，先核对校验和。
2. 完整解压 ZIP。
3. 将 `pagesage.app` 拖入「应用程序」目录，或直接在解压目录运行。
4. 当前构建使用本地 ad-hoc 签名，未做 Developer ID 签名与公证。首次打开若被
   Gatekeeper 拦截，可在「系统设置 → 隐私与安全性」中选择仍要打开，或右键
   `pagesage.app` 选择「打开」。不要为了绕过拦截而全局关闭 Gatekeeper。

系统要求：macOS 12 或更新版本；Apple Silicon（arm64）Mac。
Intel Mac 无法运行该产物。

## 数据与沙箱

应用启用 App Sandbox，包含以下权限：

- 用户选择的文件读写（导入、导出、备份）。
- 网络客户端（AI 请求与在线模型服务）。
- 应用范围的安全作用域书签（Markdown 文件夹书跨启动访问）。

EPUB、PDF 和单个 Markdown 文件导入时会复制到应用书库目录。应用数据位于
沙箱容器的 `Application Support/PageSageData`，包含数据库、书库副本、封面、
缓存与导出目录。删除或重装应用不会自动清理该目录；需要彻底删除数据时，
应同时删除沙箱容器中的对应数据。

Markdown 文件夹书是唯一不复制到书库的导入形式：

- 首次选择文件夹时，应用保存 security-scoped bookmark。
- 每次启动时在 `bootstrap` 中恢复授权，再打开阅读器或索引。
- PageSage 不写入该文件夹；从书库移除该书只删除授权记录，不删除用户目录。
- 如果文件夹被移动、改名或权限被回收，书会报告读取失败；重新选择该文件夹
  可刷新授权。

书签记录保存在数据目录的 `macos-bookmarks.json`，不包含 API key 或书籍内容。

API key 只写入 macOS Keychain。应用使用 legacy Keychain
（`MacOsOptions(usesDataProtectionKeychain: false)`），因此不需要
`keychain-access-groups` entitlement 或额外的 provisioning profile。
沙盒内的真实写入、读取和删除已通过集成测试；跨进程重启尚未单独验证。

## 本地构建与打包

需要 Xcode、CocoaPods 与 Flutter 3.44.2。构建前确认 Xcode 许可已接受：
`sudo xcodebuild -license accept`。命令：

```bash
flutter pub get --enforce-lockfile
flutter build macos --release

lipo -info build/macos/Build/Products/Release/pagesage.app/Contents/MacOS/pagesage

python3 tool/package_platform.py macos
python3 tool/package_platform.py verify
```

预期 `lipo -info` 输出只包含 `arm64`，脚本输出 `dist/pagesage-<version>-macos-arm64.zip`
并生成 SHA-256。`package_platform.py` 还会检查 `Contents/Info.plist`、图标、
`App.framework`、`FlutterMacOS.framework` 和 Flutter 资源文件是否齐全。

CI 使用 Apple Silicon runner（`macos-15`），第一步断言 `uname -m` 为 `arm64`，
随后运行分析、默认组件测试、release 构建、Mach-O 架构检查与打包。版本标签会
把 ZIP 和校验和同步到共享 Release。

## 已知限制

- 仅支持 macOS 12+ 的 Apple Silicon；不支持 Intel 或 universal。
- 未签名、未公证；Gatekeeper 首次运行需要人工确认。
- macOS 暂未接入拖拽导入（`WindowDropImportService` 目前只在 Windows 启用）；
  请使用文件选择器导入。
- macOS 暂无本地 OCR 引擎；扫描版 PDF 会明确提示 OCR 不可用，不产生伪文本层。
- 真实窗口已验收：EPUB/PDF/Markdown 导入、PDF 进度重开、Markdown 文件夹、
  Keychain 往返与原生目录书签；外部用户目录的 NSOpenPanel 授权、
  导出/备份系统面板、访达真实打开与跨机器 Gatekeeper 行为仍待人工验收。
