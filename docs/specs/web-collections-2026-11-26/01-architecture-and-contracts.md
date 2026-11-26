# 网页合集：架构与数据契约

日期：2026-11-26。本文保留早期设计及初始基线；
实际 schema 13、两表/任务账本、快照资源布局与保留策略以
[首版实现](07-implementation.md)为准，不把下文全部建议视为已落地。
需求以[主规格](README.md)为准。

## 1. 已核对的实现基线

基线：`6762bc5`，准备开始时工作树干净。以下是代码事实，不引用历史文档的旧版本推断。

| 接入点 | 当前事实 | 所需变化 |
| --- | --- | --- |
| `lib/domain/books/book.dart` | 仅 EPUB/PDF/Markdown；书籍必填路径、hash、大小 | 新增显式网页书籍类型与创建契约 |
| `lib/domain/books/book_repository.dart` | 只有导入书籍的创建接口 | 增加受管空合集创建，不伪造原文件导入 |
| `lib/core/database/app_database.dart` | schemaVersion 为 12 | 从真实 v12 升级并保留全部既有用户数据 |
| 同文件的 `DocumentSources` | 已有来源身份、地址和当前版本 | 复用来源主线，新增网页章节 kind |
| 同文件的索引 unit/generation | 已有代际与请求版本 | 按网页章节发布新索引，不先删有效代 |
| `lib/renderers/common/book_document_loader.dart` | `load(filePath)` 返回 `EpubDocument` | 接入网页章节快照装载，不合并所有网页 |
| `lib/renderers/epub/epub_chapter_parser.dart` | 基于 XHTML/XML 解析正文 | 普通 HTML 先抽取、清理与规范化 |
| `lib/features/reader/application/markdown_folder_session.dart` | 已有独立文件会话与定位转换 | 借鉴会话模式，不能复用外部目录存储语义 |
| `lib/domain/books/reading_position.dart` | 无网页类型及快照身份字段；未知类型回退 EPUB | 增加显式编解码与兼容测试 |
| `lib/features/ai/application/ai_context_source.dart` | Markdown 之外走 EPUB 装载 | 必须显式分流网页内容，避免错误解析 |
| `lib/core/tasks/task_models.dart` | 无网页获取/刷新任务类型 | 增加可恢复逐章操作及任务中心投影 |
| `lib/core/files/app_paths.dart` | 普通书路径按 hash 分区，另有可清缓存 | 为受管网页正文增加持久路径 |
| `lib/features/export/application/export_service.dart` | 备份 manifest v1 仅含数据库与封面 | 新版纳入网页快照/资源，继续读取 v1 |

## 2. 分层与抽取方案

推荐新增 `domain/web_books` 契约与 `features/web_books` 应用/界面模块，
名称和最终归属在 W1 随现有依赖统一。网络、文件存储和 Drift 实现在数据适配层；
渲染器只接收本地受控内容及资源解析器。

建议职责：

- `WebBookController`：创建合集、添加/管理章节和展示操作状态。
- `WebCaptureService`：协调下载、抽取、资源获取、候选校验和发布。
- `WebArticleExtractor`：输入 HTML、响应网址和编码信息，输出可读结构与诊断；
  不自行下载、写数据库或控制 UI。
- `WebSnapshotStore`：候选目录、不可变内容、资源校验及清理。
- `WebChapterRepository`：章节身份、快照指针、操作 epoch 与数据库事务。
- `WebBookSession`：当前章节、固定快照、局部加载和稳定位置转换。

上述名称为职责草案，不要求先建一批无消费者的空接口。先用一条纵向链路证明边界，
不为网页功能顺便重构全部 EPUB/Markdown 装载层。

抽取候选先比较 Dart 可用方案与 Readability 类算法。尚未选包、验证质量或授权引入
额外运行时。W0 须记录平台支持、许可证、依赖体积、维护情况和失败回退。
抽取与安全清理是两道步骤：抽到了正文不等于可以信任其 HTML。

## 3. 身份、版本与持久存储

### 3.1 四类身份

| 标识 | 语义 |
| --- | --- |
| `bookId` | 合集 UUID，创建空合集时生成 |
| `chapterId` | 网页章节 UUID，不随标题、顺序、重定向或正文变化 |
| `documentSourceId` | 来源 UUID，每章一个，与既有检索 provenance 对接 |
| `snapshotId` | 一次已发布本地快照 UUID；旧快照不可原地覆盖 |

URL 不是章节主键。默认以用户添加的请求网址再次刷新，实际响应网址和声明的
canonical 分别记录；不因网站重定向或 canonical 指向别处自动合并章节。
网址仅保守规范化协议/主机和默认端口，保留有意义的 query；fragment 用于页内定位。

### 3.2 拟增实体

| 实体 | 关键字段 / 约束 |
| --- | --- |
| 网页章节 | `id, bookId, documentSourceId, requestedUrl, sourceTitle, customTitle?, sortOrder, currentSnapshotId?, operationEpoch, deletedAt?, lastCheckedAt?, lastChangedAt?, acceptedRequestMetadata?, createdAt, updatedAt` |
| 网页快照 | `id, chapterId, sourceRevision, textRevision, extractorVersion, formatVersion, relativePath, manifestHash, byteSize, finalUrl, responseMetadata, fetchedAt, publishedAt` |
| 网页操作 | `id, taskId, bookId, kind, state, createdAt, updatedAt`，整书操作冻结章节清单 |
| 逐章操作项 | `id, operationId, chapterId, expectedEpoch, expectedSnapshotId?, phase, state, attempt, errorCode?, timestamps`，保存重启检查点 |

资源映射首期存于不可变快照 manifest；不为每次进度写入都重写大 JSON。
错误诊断不保存整段网页。URL、页面标题和可能带签名的资源地址属于用户数据；
常规日志仅记录内部 ID、脱敏域名、错误类型、计数和耗时。

`BookFormat.web('web')` 与 `ReadingLocatorType.web('web')` 为拟新增枚举值，
不增加可直接导入的 `.web` 文件格式。网页合集单独创建并保存于应用受管目录。
沿用现有非空字段时：

- `libraryFilePath` 指向受管合集根目录，当前设备路径由 `AppPaths` 解析。
- `fileHash` 使用命名空间与 book UUID 的规范编码 SHA-256 作为稳定身份指纹，
  不用可变正文 hash；文件导入去重不能把它当作用户文件内容 hash。
- `fileSize` 投影为当前快照集合的去重资源和正文大小；历史保留占用另行统计，
  不把两个口径混写。创建空合集时为 0。
- `DocumentSources.kind` 拟为 `web_chapter`，`address` 为书内稳定章节地址，
  例如 `web-chapter/<chapterId>`；不得把显示顺序或绝对磁盘路径当地址。

### 3.3 受管目录草案

```text
PageSageData/
  library/web/<bookId>/
    snapshots/<snapshotId>/
      article.xhtml
      manifest.json
    objects/<sha256-prefix>/<sha256>
    staging/<operationItemId>/
```

数据库是章节列表和 current 指针的唯一事实源，不再维护另一份可变章节清单。
snapshot manifest 记录版本、校验值、资源映射与完整性，不保存运行时绝对根路径。
对象按下载字节的内容 hash 存放，已发布对象不可覆盖。正文中的资源使用受控逻辑地址，
由 manifest 解析到本地对象，不能把网页提供的相对路径直接拼入文件系统。

这里的“缓存网页”是持久保存的阅读副本，**不能放进会被清理的 `cache/` 目录**。
候选与发布目录在同一受管卷内；应用正常清缓存不删除已保存正文和图片。

### 3.4 两个版本值

- `sourceRevision`：规范化可读正文、提取器/格式版本和有效资源映射的带长度编码 hash。
  映射包含资源内容 hash 或明确的缺失状态；排除获取时间、随机 snapshot UUID 和绝对路径。
- `textRevision`：既有章节解析器实际输出的原坐标正文及解析版本的 hash。
  不对正文额外 trim、分词或搜索归一化；偏移为 Dart UTF-16 code unit 的左闭右开区间。

可单独记录响应原始字节 hash 用于诊断，但不能仅凭它认定正文变化。
图片补齐或替换会生成新 snapshot/sourceRevision；若正文没变则保留 textRevision。
索引仍须核对当前 sourceRevision，允许复用文本计算结果，但不能引用旧来源冒充新版。

## 4. 获取与资源处理

1. 校验 HTTP/HTTPS URL，拒绝脚本、文件协议和 URL 内嵌账号密码；每次重定向重复校验。
   不读取浏览器 cookie、登录凭据或应用 AI 密钥。
2. 流式下载并检查状态码、Content-Type、编码、解压后体积、超时与取消。
   先覆盖用户指定页面，不让正文中的链接启动任意抓取。
3. 用 HTML parser 处理不规范标签和相对地址；抽取正文，再做受支持结构白名单转换。
   清除脚本、事件属性、iframe、表单和外部样式执行入口；不根据网页样式执行网络请求。
4. 解析正文图片的相对 URL、常见懒加载属性及 `srcset`，选择有限清晰度资源。
   仅保存进入正文的资源；去重、校验 MIME/实际解码、限制解码像素和总预算。
5. PNG/JPEG/GIF/WebP 已有基础尺寸解析能力；不据此宣称完整支持 SVG/AVIF。
   未覆盖格式在 W0 决定安全转换或保留替代文本，并报告完整性。
6. 输出规范化 XHTML，复用既有章节解析/原生渲染，产生大纲和 textRevision。
   不执行网页 JS，也不以 WebView 加载原站作为离线阅读的实现。

初始可调整预算：单页 HTML 解压后 10 MiB、单图片 20 MiB、每章资源总计 100 MiB、
图片 256 张、重定向 5 次、单请求 30 秒；解码像素上限沿用并核实既有渲染预算。
这些是待验证的保护起点，不是测出的性能结论；超限必须报告原因并保留旧快照。
批量任务初始并发按章节 2、全局资源请求不超过 8，不能随全书章节数无界增加。

HTTP 200 只有通过正文有效性和安全校验后才可进入发布。空页面、登录墙、
挑战页面与异常结构不覆盖旧版；资源缺失可以形成明确标记的可读快照。

条件请求的 ETag/Last-Modified 必须绑定同一请求表示及成功采用的响应，不能采用
一次失败提取页面的验证器。章节的 `acceptedRequestMetadata` 记录验证器及其绑定的
URL、请求表示和 current 版本；相同内容的 200 可更新它，不改写不可变快照。
URL、请求表示或 current 版本不再匹配时停用条件请求。HTTP 304 时：

- 本地正文和所需对象存在且校验通过，才报告本地版本可用。
- 本地损坏则尝试完整获取，失败时说明本地受损；有旧版可回退时明确标记回退。
- 图片未保存仍保持“不完整”，可以单独重试资源；304 不会自动补齐它们。
- 同一提取规则版本下，相同规范化正文/资源映射的 200 可报告未变化，只更新检查记录。
  提取规则升级后，手动刷新停用旧版本验证器并保存新版快照与提取版本，
  即使正文相同也不能继续保留旧版提取标记；历史快照和原文偏移不原地改写。

## 5. 候选发布与中断恢复

文件系统与 SQLite 不构成一个事务。发布遵循“完整文件先就绪，数据库短事务切指针”：

1. 任务捕获 `chapterId + operationEpoch + expectedSnapshotId`，逐阶段写入持久检查点。
   同章同类重复点击复用/合并操作；替代操作需推进 epoch。
2. 在 staging 写正文、manifest 和新对象，flush、校验、关闭句柄后移动到不可变位置。
   共享对象采用写临时文件后原子就位，不覆盖已有有效对象。
3. 短数据库事务内复核书籍/章节仍存在、未删除、epoch 及预期 current 指针仍匹配。
   写快照、切 current 指针及 sourceRevision，同步将受影响索引标记待更新。
4. 提交后才发成功通知/索引任务。旧快照不因新指针发布而立即删除。
5. 重启恢复时以数据库 current 指针为准。提交前中断留下的文件是候选孤儿，
   可重试或延迟清理；提交后中断则补派索引/更新任务投影，不重复发布快照。

取消、删章、删书和新操作均可使 epoch 失效。过期下载、迟到回调和重试不得复活已删
章节。任务中心只作操作状态投影，不能以一条“完成”通知取代每章事务结果。

整书刷新逐章独立发布，不承诺全书同时切版；结果计数总和必须与冻结清单一致。
失败项保留旧快照，取消阻止尚未提交的项；已提交章节如实记为已完成。
重启后未完成操作先展示可恢复状态，再由恢复策略续跑/重试，不显示永久“正在刷新”。

## 6. 阅读定位、批注与来源

拟新增 locator 字段：`webChapterId, snapshotId, documentSourceId, sourceRevision,
textRevision, textQuote`。`textQuote` 采用 exact/prefix/suffix 与截断标记，
具体长度沿用并核实现有来源快照策略。`chapterIndex` 仅是显示/回退提示。

内部复用 `EpubDocument` 时，网页局部 heading/block 索引与全书排序明确转换：
同一网页可有多个解析子章节，locator 仍以 `webChapterId` 确定网页，
再用局部 href/锚点与文本偏移定位。不能把局部索引直接当全书网页序号。

定位顺序：

1. 同来源、同文本版本，验证范围后精确定位；资源版本变化不必重锚正文。
2. 文本变化时只接受唯一、上下文一致的引用锚点；重锚是运行结果，不改写历史摘录。
3. 多处匹配、找不到或不支持时返回明确状态，最多回退到对应网页/标题，
   不把模糊位置画成精确高亮。
4. 历史批注和 AI 引用可查看保存时的原文；具备所需快照时可打开历史版本。
   重新定位到当前版与查看历史版是两个动作。

进度、书签、批注、笔记、搜索结果、AI 引用和导出均传递所需来源信息。
旧 EPUB/PDF/Markdown JSON 不改写；新网页 locator 必须显式解码，
不得落入现有的未知类型 EPUB 回退分支。

当前阅读会话 pin 住已打开快照；后台发布不销毁阅读器或替换选区。
切换新版时保留同一章节身份、侧栏页签与引用锚点；关闭/切章释放 pin。
全书进度按章节顺序与章内进度投影，排序后允许百分比变化，不能反向用百分比
覆盖精确位置。空合集单独处理，避免除零或越界。

## 7. 搜索、AI 与导出

- 索引单位是一章的稳定 source；查询只读可见且与当前来源匹配的 active generation。
  新代构建时保留旧代数据，但来源变化后不把旧文本作为“当前内容”返回。
- 发布快照的事务须推进 requested revision；索引提交再次比较版本与 tombstone。
  新版本暂未索引时给出明确状态，不阻止正文阅读。
- AI 装载按显式网页分支取固定快照，检索上下文冻结实际使用的文字与 provenance。
  UI 能说明章节、原网址及本地版本，网页正文仅是资料，不执行其中的指令或工具请求。
- 打开历史搜索/引用时核对版本；无法匹配当前版则提示来源变化，按历史或可靠锚点处理。
- 导出笔记保留来源网址、标题和版本信息；首期不承诺把合集发布成网站或完整 EPUB。
  备份承担本地内容完整恢复，不能以笔记导出替代。

## 8. 备份、恢复与清理

当前 backup v1 只有数据库和封面，必须扩展，不能声称新增网页数据会自动被现有 ZIP 包含。

新备份 manifest 拟升级 v2：

- 包含一致数据库快照、封面、该快照引用的网页 current 与历史保留快照、必要资源对象。
  不打包 staging、临时日志或可重建的原始下载缓存。
- 通过与发布/GC 协调的短锁建立一致数据库快照及持久保留集，再 pin 住引用文件后归档。
  不在整个压缩/下载过程中持有 SQLite 写事务。
- pin 必须在 GC 能删除任何所需文件之前生效；备份失败或取消后释放，
  崩溃后的遗留 pin 通过操作记录恢复/回收，不能永久积累。
- 清单列出文件相对路径、字节数、校验值和版本；缺失已声明完整的必要对象时失败，
  原本“图片未保存”的快照则如实保留该状态。
- 新程序继续接受 v1，按其真实内容恢复，不承诺 v1 包含网页。
  老程序不支持 v2 的情况在导出说明中明确。

恢复先安全解包、校验资源和数据库迁移，在独立目录准备完成，再切换数据库与受管
资源根。复用现有数据库生命周期协调，扩展持久恢复日志和崩溃回滚；
不能假设多目录 rename 原子。拒绝路径穿越、符号链接和超出解压预算的归档。
跨设备重建绝对路径，locator/manifest 保持可移植。失败恢复原库与原资源。

GC 从 current、批注/书签/笔记/AI 历史引用、保留策略、活动阅读会话和备份 pin
求可达快照，再求资源对象；先标记后清理，复核 epoch/锁，不能按“不是最新版”直接删除。
删除单章保留 tombstone 与仍被引用的历史；显式删除整本及其关联数据后清理无人引用资源。
磁盘空间不足时先报告占用和安全可清理项，不静默牺牲有引用的历史。

## 9. 接口与兼容变更清单

| 生产者/边界 | 必须同步的消费者 |
| --- | --- |
| 新 format 与创建接口 | 书库图标/筛选/详情、仓储映射、文件检测、元数据、任务及所有穷举 switch |
| 网页章节与快照 | 获取服务、装载器、阅读会话、大纲、管理 UI、删除与存储统计 |
| 新 locator 及版本 | 进度、书签、批注、笔记、搜索、AI、导出、旧 JSON 兼容 |
| 来源/索引版本 | DocumentSources、indexer、FTS 查询、AI 检索、来源变化提示 |
| 网页操作与检查点 | 任务中心、取消/重试、重启恢复、错误脱敏、删章/删书 |
| 备份 v2 | 导出/恢复界面、校验/回滚、旧备份、隐私说明与测试版文档 |

迁移以实施时真实最新 schema 为起点；本次不预占 v13，也不提前生成 Drift 代码。
最终 DDL、约束、索引、回填和冲突策略随 W1 完成并验证后再更新实施状态。
