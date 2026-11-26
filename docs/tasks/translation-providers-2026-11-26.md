# 翻译供应商与模型选择

日期：2026-11-26。状态：本轮供应商与配置接入完成，Linux 已静默更新。

## 本轮范围

按用户要求接入百度、DeepL、有道、腾讯 TokenHub、Qwen-MT，
支持自定义 OpenAI-compatible/LibreTranslate 与引用现有 AI 配置。
设置中「AI」和「翻译」分为两个菜单；AI 配置增加拉取模型与手动输入。
本轮交付配置、真实协议适配、固定文本测试/试译入口与后续阅读器使用的翻译服务。
网页/PDF 的双栏和持久译文沿用双语设计，不能把供应商配置完成当成阅读器对照已上线。

## 契约

- 翻译配置使用独立领域模型与 repository；小规模配置通过现有 AppSettings 保存
  带版本 JSON，不新增表，不预占 schema 版本。译文将使用后续独立存储。
- 凭据只放 secure storage，引用可轮换的随机 key；数据库只存引用与非敏感配置。
  保存前记录待清理引用，提交配置后清旧凭据，中断恢复不得删当前引用。
- AI 翻译引用 AiProfile ID，运行时读取最新配置与凭据；删除/缺失时可观察失败，
  不复制密钥，不改变 AI 当前激活组或聊天历史。
- 自定义供应商明确选择协议，不接受任意可执行请求模板；
  OpenAI-compatible 使用 Bearer，LibreTranslate 使用 api_key。
- 模型发现使用 Base URL 对应的 GET models（根地址默认 /v1/models），
  去重排序返回的 ID；失败保留手动输入。编辑地址后不得静默把旧密钥发到新地址。
- 请求有超时、响应大小限制、取消；不记录请求正文/凭据，不自动重试付费翻译。

## 验证计划

- `test/features/translation/translation_provider_test.dart`：
  本地 HTTP server 校验五家签名/请求与错误、取消、返回结构，以及自定义和 AI 引用。
- `test/core/database/translation_settings_repository_test.dart`：
  临时真实 SQLite + memory secure storage，配置保存、revision 冲突、删除、
  失败和中断清理、文件库关闭重开、JSON 中不出现 secret。
- `test/features/settings/ai_model_discovery_test.dart`：
  models 地址、鉴权、去重、无模型/格式错误、旧请求和新地址凭据隔离。
- `test/features/settings/translation_settings_test.dart`：
  菜单归属、各供应商字段、保存/试译/错误、AI 引用和窄屏。
- 受影响 AI 设置回归、flutter analyze、代表尺寸离屏截图；
  静默 Linux build/install 与 bundle 比对。不使用真实密钥或启动可见窗口。

证据：`.local-data/validation/translation-providers-2026-11-26/`。

## 实施结果

- 新增独立翻译菜单、配置组/默认项、源/目标语言、厂商适用字段、凭据保存/清除、
  重读/删除及试译。自定义供应商支持 OpenAI-compatible 与 LibreTranslate，
  其中 LibreTranslate 可无密钥。AI 翻译引用指定组，与聊天开关独立，界面已说明。
- 百度采用表单/MD5；有道采用 v3 SHA-256 签名和 Unicode 截断；
  DeepL 区分 source/target 语言代码与认证前缀；
  Qwen-MT 单条 user + translation_options；腾讯按官方指南使用
  `https://tokenhub.tencentmaas.com/v1`、`hy-mt3-plus`，模型可手填。
- AI 模型发现支持根地址 `/v1/models` 与用户版本路径 `/models`；
  列表去重排序、搜索选择，保留手填，不自动替换模型或保存草稿。
  配置切换、同组地址更新、销毁会使旧请求失效。
- 版本 JSON 明确拒绝未知/损坏数据，revision 防旧写入；
  凭据轮换先登记、后写入、再提交关联，清理失败保留可观察状态并可重试。
  SQLite trigger 模拟提交失败已证明旧配置不丢失、新孤立凭据可恢复清理。
- AI profile 软删除后 `getProfile` 不再返回旧实体，引用删除能明确反馈；
  AI 试译没有切换当前聊天配置或创建聊天历史。
- 本轮未新增依赖、数据库表或 schema 迁移。翻译配置元数据进入已有数据库备份，
  凭据仍不进入备份；用户数据未用于测试。

## 验证结果

| 证据 | 结果与边界 |
| --- | --- |
| `regression.log` | settings、AI、translation 与两类配置存储/旧 AI migration，250 PASS |
| `ui-captures.log` | 新模型选择器 2 项 + 18 项界面复验，20 PASS；与前组不重复计数，共 252 个不同用例 |
| `analyze-final.log` | 根项目 flutter analyze --no-pub，无问题 |
| `build/workbench-captures/` | 已查看翻译桌面亮色、390 宽暗色、AI 桌面与 390 宽 2 倍字号；无溢出/遮挡 |
| `ui-detector.json` | 检测器无发现，仅作辅助，视觉结论以上述实际截图为准 |
| `install-linux.log` | 静默 release 构建和本地安装成功 |
| `install-diff.log` | 完整 bundle 比对无差异 |
| `install-sha256.log` | 构建/安装 libapp.so 均为 `e0aaefe6e26d67ae4b8c1ab9973f48e4fe4edb6e208f4c57717a7c84f3224d12` |

本地 HTTP server 验证请求、签名、鉴权、错误、超时、取消与响应边界，
未使用真实密钥验证云端账单和翻译质量；Windows/Android 未做真机验收。
未新开窗口或重启现有进程。阅读器双栏、PDF 当前页入口与持久译文仍未接入。

## 下拉选项样式修整（2026-11-26）

用户反馈 AI 配置与翻译协议菜单横向铺满表单、选中底色和阴影过重。
本轮统一这两个设置区域的选择控件：菜单宽度按内容尺度限制、选项内缩圆角、
选中项有勾选，统一悬停/焦点/禁用状态。保留当前配置草稿和供应商切换逻辑。

修改前验证计划：共享选择器覆盖宽度/上下定位、鼠标与键盘选项、取消、
禁用/加载与大字号；AI/翻译真实设置页验证菜单归属和供应商切换，
截图必须捕获菜单展开态，覆盖桌面亮暗和窄屏。
命名测试为 `test/app/widgets/app_select_field_test.dart` 与受影响 settings 回归；
证据目录为 `.local-data/validation/settings-select-menus-2026-11-26/`。

交付结果：

- AI 配置与翻译的配置组、供应商、协议、AI 引用、源/目标语言已使用共享
  `AppSelectField`，菜单约 304 px 起，字号调整后不超过 400 px，
  不再跟随宽表单铺满；使用细边框、轻阴影、内缩选项、勾选及辅助模型名。
- 长列表限高滚动，窄屏受窗口约束；方向键/Enter/Esc、外部关闭、空值、
  禁用和加载行为已验证。菜单滚动条使用主题色，避免深色下出现突兀白条。
- `focused-verified.log`：24 PASS，含真实设置页展开态捕获；截图通过测试 binding
  启用真实阴影，不把测试调试模式的阴影描边当成发布样式。
- `regression-release.log`：当前实现下选择器及 settings 共 98 PASS；
  `analyze-final.log` 无问题，`ui-detector.json` 无发现。
- 已查看桌面亮色协议菜单、暗色供应商菜单、窄屏 1.5 倍字号协议菜单和
  AI 配置菜单展开截图。图片位于 `build/workbench-captures/`。
- `install-linux.log`：Linux release 静默构建/安装成功；
  `install-diff.log` 无差异，构建/安装 libapp.so SHA-256 均为
  `6ba0213a276c92d99159b08bfd6207195ce20badde7a5a26a4e43559a1f5ed3a`。
  未新开窗口或重启已有进程。此次没有模型、存储协议或依赖变化。

## 翻译请求间隔（2026-11-26）

用户要求可配置翻译 API 调用频率，默认间隔 1 秒。本次范围：

- 每组翻译配置保存 `requestIntervalMs`，单位毫秒，默认 1000，
  设置界面以秒输入，支持小数，允许 0～60 秒；0 表示不额外等待。
- 试译、网页/PDF 分段及 AI 翻译共用串行队列。前一请求结束后等待间隔，
  两次请求配置不同则取两者较大值，避免并发或切换配置绕过限速。
- 排队和等待期间可取消；失败不阻塞后续请求；真正发出前重新检查配置版本。
  读取已有译文缓存不进入队列，间隔变化不改变译文语义指纹。
- 旧 JSON 缺字段补 1000；显式 null、非整数、越界数据报错。
  配置复制、语言覆盖、备份恢复及文件库重开必须保留间隔；
  复用版本 1 设置 JSON，无数据库 schema 变更。

实施前验证计划：新增调度器可控时钟测试，验证串行、完整请求结束后的间隔、
取消和错误恢复；服务层验证试译/阅读器入口共享队列、排队期间配置失效；
真实临时 SQLite 验证缺省/边界/文件库重开与备份恢复；
设置组件验证默认值、保存/重读、非法输入、窄屏及大字号离屏布局。
运行受影响翻译/设置/网页与备份回归、静态分析，最后静默构建安装并比对产物。
证据目录：`.local-data/validation/translation-rate-limit-2026-11-26/`。

交付与验证结果：

- 配置模型、设置保存/重读、语言覆盖、恢复准备和阅读器服务均已接入间隔。
  所有翻译供应商共用同一服务队列；AI 聊天的请求入口未作修改。
- 调度测试使用可控时钟证明首次立即、请求不重叠、结束后完整等待 1 秒、
  切配置取较大间隔、排队/冷却取消不发请求、失败后继续。
  服务测试证明试译与阅读器入口共用队列，排队期间修改/删除配置会在发出前拒绝。
- 临时真实 SQLite / memory secure storage 验证旧字段缺省、无效值拒绝、
  保存不丢凭据、文件库关闭重开，以及恢复后间隔保留。
  缓存测试证明修改间隔仍复用已保存译文，不增加请求。
- `regression-final.log`：上述模型、配置存储、翻译、设置、网页阅读器和导出备份
  共 **114 PASS**；未声明全仓回归。`analyze.log`：无问题。
- `ui-captures.log`：2 项离屏复验通过，为上述 114 项中的重复用例；
  已查看 1280 宽亮色与 380 宽暗色 2 倍字号的请求间隔字段，未见溢出/遮挡。
- `install.log`：Linux release 静默构建安装成功；`install-diff.log` 无差异，
  `install-sha256.log` 中构建/安装 `libapp.so` 均为
  `0ed9f6517792e12dac5d50da4bb374630f49ef914f678342b1beb19b88fca6f0`。
  没有启动或重启应用窗口，没有访问真实付费翻译接口。
