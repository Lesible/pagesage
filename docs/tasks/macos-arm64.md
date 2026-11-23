# macOS arm64 集成

## 2026-11-23 续接与上游整合

- 上游 `DCAM-03/pagesage` 的 `main` 新增 `da3f8ce`、`a4547f6`、`6762bc5`，本地 macOS 提交已 rebase 到 `6762bc5`；保留原有 AI 模型目录、本地 OCR 和沙盒导出修改。
- 待证明行为：macOS 拖拽沿用上游悬停状态、启停与单文件直接阅读；图片批注仅向保存面板选择的 ZIP 写入，包内 Markdown 相对链接可解析，缺图仍保留评论，取消不覆盖原文件。目标为已有目录或目标父路径被文件占用时，打包与归档导出均保留目标原内容，并清空隔离临时目录中的工作目录和 `.part` 文件。
- 最小验证：`test/core/platform/window_drop_import_service_test.dart`、`file_picker_service_test.dart`、`test/features/library/library_file_drop_test.dart`、`test/features/export/export_service_test.dart`、`test/features/settings/settings_export_test.dart`；上游 EPUB 跳转与阅读位置使用其命名测试。测试仅用临时书库、伪安全存储和离屏 widget，不访问真实用户数据。
- 执行环境：本机 macOS arm64；静默构建、签名与打包核对，不启动可见窗口。Windows、Android、Linux 安装及系统保存面板的真实交互另记验证边界。
- 上游再次 fetch 后仍为 `6762bc5`，已包含其全部提交；fork 远端整合前的 macOS 分支为 `1161575`。`git range-diff` 确认该提交与 rebase 后的 `b469601` 补丁等价，原有开发成果保留。
- 验证：完整默认回归 1169 PASS / 27 SKIP（`/tmp/pagesage-macos-20261123-full-test.log`）；最后的备份及图片归档失败清理修复，另跑导出与设置导出 36 PASS（`/tmp/pagesage-macos-20261123-final-export-test.log`）。隔离临时目录测试覆盖目标为目录、父路径被文件占用两类发布失败，打包与完整图片归档导出均不残留 `.part` 或工作目录；原文件与目标内容保留。23 个变更 Dart 文件格式化通过，`flutter analyze --no-pub` 无问题。
- 静默 Release 构建成功（48.4MB）。增量构建更新 `App.framework` 后旧签名失效，已显式使用 Release entitlements 重新做 ad-hoc 签名；构建目录与 ZIP 解压后的应用包均通过 `codesign --verify --deep --strict`。应用包全部 5 个 Mach-O 文件都仅包含 arm64，签名中的 entitlements 与源文件完全一致；framework 符号链接和主程序执行权限保留。
- 最终产物：`dist/pagesage-0.0.1+2-macos-arm64.zip`，22,497,527 字节（约 21.46 MiB）；SHA-256：`c91c02a997387cc2d9aa4d30d06eeee0235b7227334148399f5ea5bd8617898c`，`package_platform.py verify` 通过。构建、签名、解压后校验日志分别为 `/tmp/pagesage-macos-20261123-final-build.log`、`/tmp/pagesage-macos-20261123-final-signature.log`、`/tmp/pagesage-macos-20261123-extracted-signature.log`。
- macOS CI 新增打包前重新签名与严格校验，避免旧外层签名进入分发包；本地执行已通过，GitHub job 尚未实际运行。系统保存面板重新导出、外部目录授权、Keychain 跨进程与跨机器 Gatekeeper 仍待验收；本轮未启动可见窗口，不覆盖这些运行时边界。

- 日期：2026-11-12
- 当前状态：代码集成、构建、打包与本地运行时验收已完成（2026-11-13）；
  Finder 拖拽导入与 Apple Vision 本地 OCR 已接入，窗口 drop 入口与 OCR
  均有真实运行时证据，用户本机手动拖拽与识别也已生效；
  Markdown 导入与访达定位已由用户手动确认；数据库备份的沙盒路径问题已修复，
  待用系统保存面板重新导出验证；GitHub macOS job 与外部用户目录
  NSOpenPanel 授权待完成
- 用户目标与本次交付边界：按用户 2026-11-12 的明确要求，把 macOS arm64 纳入目标平台。
  首个可交付切片要求：在 macOS arm64 上可构建、启动，并完成
  「导入 EPUB/PDF/Markdown → 阅读 → 保存进度 → 关闭后重开恢复」；
  搜索、设置、安全存储、导出/备份可用；产出可核对的本地分发包。
  首个切片不包含 Mac App Store、Developer ID 公证、Intel/universal 承诺、iOS、
  云同步或新增业务功能。
- 相关设计、既有任务与实际实现入口：根 `AGENTS.md`、`docs/01-product-requirements.md` §13、
  `docs/05-technical-architecture.md`、`docs/07-roadmap.md`、
  [平台集成](platform-integration-android-windows.md)、
  [打包与发布](packaging-release-and-operations.md)、
  `tool/package_platform.py`、`tool/generate_app_icons.py`、`.github/workflows/`。

## 当前事实与预期行为

- 2026-11-13 已生成 `macos/` 平台目录，并在 `.metadata` 登记 macOS 平台迁移；
  bundle id 为 `dev.pagesage.pagesage`。
- 本轮主机为 macOS 27.2.1 arm64。2026-11-12 已准备工具链：
  Flutter 3.44.2 / Dart 3.12.2（FVM，`~/fvm/default` 并已加入 `PATH`）、
  CocoaPods 1.17.0、Xcode 27.2（`xcode-select` 已指向
  `/Applications/Xcode.app/Contents/Developer`，macOS SDK 27.2）。
  `flutter doctor` 仅剩 Android SDK 缺失和 iOS Simulator runtime 缺失；
  macOS 桌面构建不依赖这两项。`dart` MCP 已连接，`analyze_files` 可用。
- Release 构建与 arm64 产物已完成本地验证，证据见下方「执行结果」。
- 阅读器主体是 Flutter/Dart；PDF 使用纯 Dart Canvas 渲染，不依赖 WebView。
  因此阅读核心原则上可移植，主要工作集中在平台服务、沙箱文件访问、打包与 CI。
- 已识别的平台缺口：
  1. 文件选择/保存依赖 `file_picker` 与 `file_selector`，代码已有部分 macOS 分支，
     但没有 macOS 专属选项，也没有在 macOS 上验证过保存、多选和目录选择。
  2. `OpenFileLocationService` 只支持 Windows/Linux，macOS 缺少「在访达中显示」。
  3. `WindowDropImportService` 只在 Windows 启用，macOS 拖拽导入未实现
     （后续 2026-11-13 已实现）。
  4. macOS 会落到 `StubOcrEngine`/`StubPdfPageRasterizer`；扫描版 PDF 必须明确提示
     OCR 不可用，不能崩溃，也不能伪造可搜索/可划词能力
     （后续 2026-11-13 已接入 Apple Vision）。
  5. `flutter_secure_storage` 在 macOS 使用 Keychain，沙箱 entitlement 与重开读取未验证。
  6. `sqlite3` 通过 native asset / hook 随包加载，macOS arm64 产物未验证。
  7. `tool/package_platform.py` 只有 windows/android/verify；
     `tool/generate_app_icons.py` 不生成 macOS `.icns`；CI 没有 macOS job。
  8. 默认 Flutter macOS 工程启用 App Sandbox。文件导入会复制到应用书库目录，
     但 Markdown 目录书是就地读取：要跨启动持续访问用户目录，需要 security-scoped
     bookmark，或明确选择非沙箱分发。这个决定必须先记录，不能边写边猜。
  9. AI 请求需要外向网络；Release entitlement 必须显式允许网络客户端。
- 2026-11-13 实施后的缺口状态：2 已补访达显示并由用户手动确认；
  3 已补 Finder 拖拽导入（窗口 `NSDraggingDestination` 入口已用真实
  pasteboard 运行时验证，用户也已手动拖拽成功）；4 已接入 Apple Vision
  本地 OCR；7 已补打包、图标与 CI；8 采用决策 A（App Sandbox +
  security-scoped bookmark）；9 已加入网络 entitlement。
  1 的 Markdown 文件导入与访达定位已由用户手动确认，外部目录/文件夹书
  的 NSOpenPanel 授权仍待验证；
  5（Keychain）已做真实沙盒往返，跨进程重启仍未单独验证；
  6（SQLite 运行时加载）已由真实窗口测试验证。
- 预期行为：macOS arm64 构建可启动；完成上述阅读闭环；数据保存在
  Application Support 下的应用目录；Keychain 密钥重启后仍可读；
  扫描页 OCR 显示明确不可用原因；窗口缩放、键盘快捷键和桌面三栏布局可用。

## 实施范围与依赖

- 受影响模块和入口：
  - 新平台壳：`macos/`（Runner、entitlements、窗口最小尺寸、菜单、`.icns`）。
  - 平台服务：`lib/core/platform/`（文件选择、访达显示、拖拽、路径）。
  - 安全存储与数据库初始化：`lib/core/security/secure_store.dart`、
    `lib/core/database/app_database.dart`、`lib/core/files/app_paths.dart`。
  - OCR 能力选择：`lib/features/ocr/application/ocr_providers.dart`。
  - 打包与 CI：`tool/package_platform.py`、`tool/generate_app_icons.py`、
    `test/tool/`、`.github/workflows/`。
  - 文档：`docs/01-product-requirements.md` §13、`docs/07-roadmap.md`、
    `docs/05-technical-architecture.md`、`README.md`，并新增 macOS 分发说明。
- 硬依赖与待确认决策：
  - Flutter 3.44.2（与 CI 固定版本和 `.metadata` revision 对齐）、Xcode、CocoaPods。
  - 决策 A：保持 App Sandbox + security-scoped bookmark，或首个测试包改为非沙箱。
    推荐前者，但必须先验证目录书跨启动可读；后者只作为明确的临时分发策略。
  - 决策 B：首个切片 OCR 延期（Stub + 明确提示），还是同时接入 Apple Vision
    `VNRecognizeTextRequest`。推荐先延期，OCR 作为独立切片，避免阅读闭环被引擎适配拖住。
    后续已在 2026-11-13 的增量中接入 Apple Vision，见「执行结果」。
  - 决策 C（已确认 2026-11-12）：产物只做 arm64，不构建 universal；
    仍须用 `lipo -info` 检查产物确实包含 arm64，不能只凭构建主机架构推断。
  - 决策 D：首个包是否要求 Developer ID 签名与公证。没有签名/公证时，
    Gatekeeper 会拦截下载包；本地开发构建不受同等影响。
- 内部实施顺序：
  1. 工具链核对与 `flutter create --platforms=macos .`；先检查生成文件冲突，
     不覆盖 `docs/`、`AGENTS.md` 和既有平台目录。
  2. 平台服务与 entitlement：文件对话框、访达显示、Keychain、网络、SQLite 读写。
  3. 沙箱/目录书访问决策落地并验证跨启动读取。
  4. 阅读闭环与现有组件测试在 macOS 主机上跑通。
  5. 图标、打包脚本、CI job、产物校验。
  6. 分发文档、支持矩阵与未验证边界。
- 涉及协作时的写入归属与交接候选：本轮不拆分会话；实施时由当前会话完成，
  高风险项（沙箱文件访问、Keychain、打包签名）在完成声明前单独列出证据。

## 契约与兼容（涉及跨平台行为时）

| 契约 / 不变量 | 权威来源与生产者 | 实际消费者 | 旧数据与错误语义 | 验证及结果 |
| --- | --- | --- | --- | --- |
| 导入复制到应用书库，删除书籍不删原文件 | `AGENTS.md`、导入服务 | 书库、备份、导出 | macOS 沙箱只授予用户所选路径的临时访问；复制完成后不依赖原路径 | 真实 app 导入 EPUB/PDF/Markdown 后副本落在容器 `PageSageData/library`；删除书不删原文件待验证 |
| Markdown 目录书就地读取、不复制、不写入 | `AGENTS.md`、`docs/tasks/markdown-reading.md` | Markdown 阅读器、进度、搜索 | 跨启动需 security-scoped bookmark；不能靠一次选择长期访问 | 真实窗口读取与文件树通过；原生书签跨实例恢复通过；外部用户目录 NSOpenPanel 授权待手动 |
| API key 只进安全存储 | `AGENTS.md`、`secure_store.dart` | AI 设置与请求 | macOS Keychain 条目在重启后可读、不可被日志输出 | 真实沙盒 Keychain 写入/读取/删除通过；跨进程重启未单独验证 |
| OCR 能力如实上报 | `ocr_providers.dart`、OCR 能力模型 | 阅读器工具栏、搜索、划词 | macOS 使用 Apple Vision；系统不支持所选语言时明确提示，不产生伪选区/伪搜索 | 真实窗口 PDF 栅格化 + Vision 识别通过；语言不可用提示由 MethodChannel 单测覆盖 |
| Finder 拖拽只导入单本书文件 | `window_drop_import_service.dart`、`MainFlutterWindow.swift` | 书库导入流程 | 只接受非空路径；文件夹不从拖放猜测；不支持文件给提示 | Dart 通道测试 3 PASS；真实窗口 drop 入口 + 真实 pasteboard + 书库导入集成测试通过；OS 级手势未自动化 |
| 导出/备份目标路径由用户选择 | 导出服务、文件保存适配器 | 笔记、书签、备份、图片 | macOS 保存面板与沙箱写入权限必须可用；取消不写半成品 | 用户实测数据库备份报 `SqliteException(14)`；已改为临时目录暂存后发布最终文件，待保存面板复验 |
| 应用数据目录升级不清理用户书库 | `app_paths.dart`、数据库初始化 | 全部本地数据 | 重装/升级只替换程序，Application Support 数据保留 | 真实 app 退出后重新启动仍读到 3 本书；升级/重装未验证 |

## 最小验证矩阵

| 行为或反例 | 精确测试文件 / 场景 | 样本、平台与配置 | 预期信号 | 实际结果与证据 |
| --- | --- | --- | --- | --- |
| 工具链可用 | `flutter doctor -v` | macOS arm64、Flutter 3.44.2、Xcode | macOS toolchain 与 Xcode 均通过 | 通过：Flutter 3.44.2 / Dart 3.12.2、Xcode 27.2、macOS SDK 27.2；Android SDK / iOS Simulator 缺失不影响 macOS |
| Release 构建为 arm64 | `flutter build macos --release`，再 `lipo -info` 检查可执行文件 | macOS arm64 | 退出码 0，产物为 arm64；不构建 universal | 通过：48.2MB；主程序与 `FlutterMacOS.framework` 均为 arm64，无 x86_64 |
| 静态分析与受影响测试 | `flutter analyze`；按改动的命名测试文件运行，`--concurrency=4` | macOS 主机 | 无分析错误；受影响行为测试通过 | 通过：`flutter analyze --no-pub` 无问题；文件夹授权、访达显示、设置导出 21 PASS；打包/发布工具 33 PASS；完整默认回归 1125 PASS / 26 SKIP |
| 启动与空书库 | 打开 `build/macos/Build/Products/Release/pagesage.app` | macOS arm64 | 窗口出现，无崩溃，空状态可操作 | 通过：真实 Release 启动，创建沙盒 `PageSageData/database/pagesage.sqlite`（user_version 12，0 本书），无崩溃报告 |
| 三格式导入 | 导入 EPUB、PDF、Markdown 单文件 | 仓库样本或 `tool/generate_manual_samples.dart` 产物 | 书库出现记录，文件复制到应用书库 | 通过：真实 app 启动导入 3 本书，副本在容器 `PageSageData/library`；`macos_platform_test.dart` 通过生产 `ImportUseCase` 导入 3 本；用户手动导入 Markdown 成功 |
| 目录书就地读取 | 导入 Markdown 文件夹；退出并重开应用后再次打开 | 用户目录中的测试文件夹 | 不复制目录；重开仍可读；应用不写入该目录 | 真实窗口渲染文件夹书与文件树通过；原生 security-scoped 书签跨实例恢复/删除通过；外部用户目录 NSOpenPanel 授权未自动化 |
| 进度恢复 | 打开 PDF 到非首页，记录 locator；退出重开 | macOS arm64 | 回到同一页/页内位置 | 通过：PDF 跳到 3/3，关闭阅读器后重开仍为 3/3；真实 app 重启后仍读到 3 本书 |
| 搜索与跳转 | 对含文本层 PDF 执行书内搜索和全局搜索 | macOS arm64 | 命中并跳转；扫描页不出现伪命中 | 检索链路通过：真实 app 导入并完成索引后 FTS `MATCH 'RunbookToken'` 命中；阅读器搜索 UI 由组件测试覆盖，未单独驱动 |
| Keychain 持久化 | 保存测试 API key，退出重开，读取并删除 | macOS arm64 | 重开仍存在；日志无密钥；删除后不可读 | 通过：沙盒内真实 Keychain 写入/读取/删除；测试 key 已删除。跨进程重启未单独验证 |
| 导出/备份 | 导出笔记 Markdown、书签 CSV、完整备份 | macOS 保存面板 | 文件可打开、内容有效；取消不产生半成品 | 用户备份复现 `SqliteException(14)`；已改为系统临时目录暂存并发布最终文件，自动回归覆盖暂存不留残片；待保存面板重新导出复验 |
| 扫描页 OCR | 对无文本层 PDF 执行当前页/范围/整本识别 | macOS arm64 | 本地引擎可识别；越界/缺语言返回明确错误；不崩溃、不伪造伪选区 | 真实窗口 PDF 栅格化 + Apple Vision OCR 通过（生成文本 PDF、`/Rotate 90`、中英文行框与越界页错误）；真实扫描书籍质量未自动化 |
| Finder 拖拽导入 | 把 EPUB/PDF/Markdown 拖到窗口 | macOS arm64 | 只导入支持的单个文件；文件夹提示改用导入菜单；不支持的项给出提示 | 真实窗口 drop 入口通过：调试钩子在 `NSPasteboard` 写入文件 URL 后调用窗口实际 `performDragOperation`，生产导入流程落库并复制到书库；OS 级拖拽手势未自动化 |
| 打包与校验 | `python3 tool/package_platform.py macos` | 本地 Release 产物 | 生成 `pagesage-<version>-macos-arm64.zip` 与 `.sha256`，校验通过 | 通过：生成 22MB ZIP 与 SHA-256；解压后 `codesign --verify --deep --strict` 通过，符号链接保留 |
| CI 构建 | 新增 macOS arm64 workflow job | GitHub macOS runner；先 `uname -m` 确认架构 | 构建、测试、打包、上传产物成功 | workflow 已新增（`macos-15`、arm64 断言、lipo 门禁）；尚未实际运行 |
| 桌面交互 | 窗口缩放、快捷键、菜单、访达显示 | macOS arm64 | 行为与 Windows 桌面约定一致；无控件遮挡正文 | 通过：PDF 12 项、Markdown 4 项、EPUB 1 项、设置 1 项真实窗口测试；用户手动确认「在访达中显示」成功 |

- 可复用证据及为何仍有效：纯 Dart 的解析、数据库、布局与检索测试可在 macOS 主机复用，
  但仍需在 macOS 上实际运行；Linux/Windows 的平台服务、安装与打包证据不能外推到 macOS。
- 必要重跑与原因：平台服务、entitlement、SQLite native asset、打包脚本和图标产物
  发生变化后必须重跑对应验证。
- 未验证的平台 / 真实运行 / 外部依赖及其对结论的影响：Developer ID 签名与公证、
  Intel/universal、App Store、其他 macOS 版本、外部用户目录的 NSOpenPanel 授权、
  导出/备份在系统保存面板上的复验、GitHub macOS job 实跑。
  未执行项不能写成已通过。

## 执行结果

- 实际完成的行为、代码与文档（2026-11-13）：
  - 平台壳：`macos/`（Runner、`Release.entitlements`、`DebugProfile.entitlements`、
    `ARCHS = arm64`、最低 macOS 12、应用图标、窗口标题与最小尺寸）。
  - 平台服务：`OpenFileLocationService` 支持 macOS 访达定位与打开目录；
    `FilePickerService` 只在「将文件夹作为一本书导入」时保存授权，避免为
    普通文件夹扫描积累无用书签；`bootstrap` 启动时恢复书签；
    移除文件夹书时清理授权；`SecureStore` 在 macOS 使用 legacy Keychain，
    避免 `keychain-access-groups` 的 provisioning 依赖。
  - 沙箱访问：`lib/core/platform/macos_folder_access.dart` +
    `MainFlutterWindow.swift` 的 `pagesage/macos_bookmarks` MethodChannel。
  - 打包与 CI：`tool/package_platform.py macos`、`tool/generate_app_icons.py`
    生成 macOS 图标、`.github/workflows/macos.yml`。
  - 测试：新增 `macos_folder_access_test.dart` 与
    `integration_test/macos_platform_test.dart`，扩展访达显示、设置导出与
    平台分发测试。
  - 文档：本任务、`docs/macos-distribution.md`、README、测试版说明、
    产品需求、架构、路线图与实现记录。
- 验证命令、结果与必要的证据路径：
  - `flutter analyze --no-pub`：No issues found（12.4s）。
  - `flutter test --no-pub --concurrency=4 test/core/platform/macos_folder_access_test.dart
    test/core/platform/open_file_location_service_test.dart
    test/features/settings/settings_export_test.dart`：21 PASS。
  - `python3 -m unittest discover -s test/tool`：33 PASS。
  - `flutter test --no-pub --concurrency=4`：1115 PASS / 26 SKIP（完整默认回归）。
  - `flutter build macos --release --no-pub`：成功，48.2MB。
  - `lipo -info`：主程序 `arm64`；`FlutterMacOS.framework` 只含 `arm64`。
  - `codesign -d --entitlements :-`：app-sandbox、network.client、
    user-selected.read-write、bookmarks.app-scope；无 `get-task-allow`。
  - `python3 tool/package_platform.py macos`：生成
    `dist/pagesage-0.0.1+2-macos-arm64.zip`（22MB）与 `.sha256`；
    `python3 tool/package_platform.py verify` 通过。
  - 解压后 `codesign --verify --deep --strict` 通过；framework `Current`
    符号链接保留；ZIP 含程序、Flutter 资源与许可文件。
  - 真实窗口运行时验收（全部在沙盒化 macOS app 内执行）：
    - `flutter test integration_test/macos_platform_test.dart -d macos`：7 PASS。
      覆盖生产 `ImportUseCase` 导入 EPUB/PDF/Markdown、FTS 命中
      `RunbookToken`、真实窗口 drop 入口导入、PDF 跳到 3/3 后关闭重开恢复、
      EPUB 与 Markdown 文件夹窗口渲染、真实 Keychain 往返、
      原生 security-scoped 书签跨实例恢复，以及 PDF 栅格化 + Apple Vision 本地 OCR。
    - `flutter test integration_test/reader_s0_test.dart -d macos`：12 PASS。
      覆盖 PDF 渲染、鼠标划词菜单、标注菜单、页码跳转、扫描 PDF 降级、
      第 40 页重开、窄窗口、Ctrl+滚轮缩放、旋转页、连续滚动和长按选词。
    - `reader_epub_image_test.dart`：1 PASS；`reader_markdown_test.dart`：4 PASS；
      `settings_window_test.dart`：1 PASS。
    - 真实 Release app 启动：进程存活，沙盒容器创建
      `PageSageData/database/pagesage.sqlite`（user_version 12，0 本书），
      无崩溃报告。
    - 使用 `PAGESAGE_VERIFY_IMPORT_PATHS` 启动真实 Debug app，导入
      EPUB/PDF/Markdown 3 本；副本写入容器 `PageSageData/library`，
      3 本索引状态均为 `done`，`search_chunks` 9 条，
      FTS `MATCH 'RunbookToken'` 命中 1 条；退出后重新启动 Release app
      仍读到 3 本书。
    - 验收后已退出所有可见实例，删除测试书库、容器内样本和测试 Keychain key；
      截图保存在容器 `Data/build/integration-captures/macos-01-pdf-restored.png`
      与 `macos-02-markdown-folder.png`。
    - 说明：桌面验收套件默认从仓库 `poc_pdf_canvas/samples` 读取样本，
      macOS App Sandbox 无法读取仓库路径；本轮把样本生成到 app 容器后运行，
      未修改产品读取路径。
- 2026-11-13 增量：Finder 拖拽导入与 Apple Vision 本地 OCR
  - `WindowDropImportService` 在 Windows 之外启用 macOS；
    `MainFlutterWindow` 声明 `NSDraggingDestination`、注册 `.fileURL`，
    `performDragOperation` 读取文件 URL 并通过 `pagesage/window_drop`
    的 `filesDropped` 发送路径，沿用书库导入与不支持文件提示；
    文件夹仍由导入菜单决定。
  - Debug 构建新增 `pagesage/test_drop` 验证通道：把真实文件 URL 写入
    `NSPasteboard` 后调用窗口实际的 `performDragOperation`，用于在无
    Accessibility 权限、无法合成 OS 级拖拽手势时驱动真实 drop 入口；
    Release 构建通过 `#if DEBUG` 排除该通道。
  - `PagesageNativeChannels.swift` 新增 `pagesage/pdf_raster` 与
    `pagesage/ocr`：CoreGraphics 栅格化（DPI、最长边、500 万像素预算、
    白底、JPEG/PNG）与 Vision `VNRecognizeTextRequest`（行级 0..1 框、
    top-left 原点、`macos-vision`、书籍语言到 Vision 标签映射）；
    `ocr_providers.dart` 在 macOS 选择这两个 MethodChannel 实现，替换 Stub。
  - 验证：`flutter analyze` 无问题；窗口拖放通道与 MethodChannel OCR 定向测试
    6 PASS；完整默认回归 1125 PASS / 26 SKIP；release 构建成功（48.3MB，
    `lipo -info` 主程序 arm64）；重新打包
    `dist/pagesage-0.0.1+2-macos-arm64.zip`（22MB）并通过 SHA-256 与
    解压后 `codesign --verify --deep --strict`；
    `flutter test integration_test/macos_platform_test.dart -d macos` 7 PASS。
    其中 drop 用例在真实沙盒 app 内通过真实 `NSPasteboard` 调用窗口
    `performDragOperation`，生产导入流程把 EPUB 复制进书库并落库；
    OCR 用例栅格化生成的文本 PDF，识别出 `PageSage`/`RunbookToken`，
    校验 `engine=macos-vision`、行框范围、`/Rotate 90` 页面横向栅格化、
    `supportedLanguages` 与越界页错误。
  - 用户本机手工验收（2026-11-13）：从访达拖到窗口可导入；对真实中文 PDF
    执行「识别文字」后，沙盒数据库 `ocr_pages` 有 2 页记录，
    `engine=macos-vision`、`language=zh-Hans`，置信度 0.72 / 0.849，
    证明实际走本地 Apple Vision 通道（该通道无网络请求）。
    识别文本有可见误差（「机器人」→「机嚣人」），真实扫描件质量/耗时
    仍不作为已验收指标。
  - 未验证：GitHub macOS job 的实际运行；真实扫描件的质量与性能基准。
- 相关候选身份（源码差异 / 依赖 / 配置 / 样本）：Flutter 3.44.2（revision
  `c9a6c484230f8b5e408ec57be1ef71dee1e77020`）、Xcode 27.2、CocoaPods 1.17.0；
  未新增 Dart 包；bundle id `dev.pagesage.pagesage`。
- 本地安装：已在授权后启动可见 Release/Debug 应用完成运行时验收；所有实例均已退出，
  测试数据与测试 Keychain key 已清理。
- 当前剩余阻塞、缺陷或明确未做项：外部用户目录的 NSOpenPanel 授权、
  导出/备份在系统保存面板上的复验、Gatekeeper 在另一台 Mac 上的行为、
  Keychain 跨进程重启、GitHub macOS job 实际运行、
  真实扫描书籍 OCR 质量基准尚未验证；OS 级拖拽手势、本地 OCR、Markdown
  导入与访达定位已由用户本机手动确认生效；
  图片标注导出仍会在所选 Markdown 旁创建图片文件夹，沙盒下可能需要改为
  目录选择或 ZIP；
  无 Developer ID 签名与公证；不支持 Intel/universal。
