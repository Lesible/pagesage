# W0 网页抽取、原生转换与截图问题验证

日期：2026-11-26。状态：抽取选型原型完成，网页合集应用入口尚未实现。
代码在 `tool/web_capture_eval`；根项目另有一项经过回归的列表样式/点击范围修复。

## 1. 本轮实际交付

- 独立 Dart/Flutter 工具包，根 `pubspec.yaml` / lock 不接入尚未发布的网页依赖。
- 24 个自建冻结 HTML 用例，覆盖短文、中文、错误嵌套、代码、表格、
  Unicode、重复标题、懒加载、srcset、资源地址、登录墙、挑战页与框架空壳。
- 12 个冻结真实网页输入，包括用户指定的 Anthropic 工具文章和 LangGraph persistence。
  真实输入及输出仅保存在被忽略的本地证据目录。
- 三种策略比较、安全白名单、资源引用提取、节点/深度/体积/图片数量预算。
- 安全 XHTML 到现有 `EpubDocument` 的原型适配，保留代码空白、表格、内联样式、
  链接、嵌套大纲和 UTF-16 区间；未另写渲染引擎。
- 使用现有阅读组件完成两篇用户样本的亮/暗离屏装载和截图。

本轮没有实现 HTTP 图片下载、真实快照落盘、合集创建/刷新队列、schema 迁移或双语翻译。
原型已解析图片引用不等于已保存图片，离屏装载不等于产品阅读流程验收。

## 2. 选择结果与度量边界

| 候选 | 冻结用例达标 | 真实网页检查达标 |
| --- | --- | --- |
| reader_mode 0.2.3，HTML adapter | 22 / 24 | 2 / 12 |
| reader_mode 0.2.3，JSDOM adapter | 21 / 24 | 2 / 12 |
| 语义正文区域优先 + HTML adapter 回退 | 24 / 24 | 12 / 12 |

三者共用预算、预清理和安全输出；并非官方 Mozilla JavaScript 版本的对比。
冻结用例以人工预期完整片段计算去空白字符保留率与杂质比例，门槛为 95% / 5%。
真实网页只做人工指定的标题锚点和代码/表格/图片引用数量检查，
**没有完整正文金标，不能说真实网页准确率或正文保留率为 100%**。
文档型页面丢标题或代码也会检查失败，不能把 2/12 解释成通用文章提取成功率。

选择进入后续阶段的方案：语义文章区域优先、启发式抽取回退、白名单输出，
并用专门 HTML block adapter 接入现有原生模型。不要直接将网页塞入旧 XHTML 解析器。
root `EpubChapterParser` 保留为对照，也保留其既有 EPUB 生产行为。

依赖仍局限于工具包。reader_mode / HTML parser 为 Dart 实现，
实际 adapter 路径的许可证与第三方声明在应用接入前复核；
不因此要求用户安装浏览器、Go 或 Python。Python 仅用于研究工具下载测试输入。

## 3. 用户提供样本

下列文字长度是抽取纯文字的 UTF-16 单位，不是单词数。
图片数量指已提取、去重的资源地址，不是下载完成数量。

| 样本 | 文字长度 | 标题 | 代码块 | 表格 | 图片引用 |
| --- | --- | --- | --- | --- | --- |
| Anthropic：Writing tools for agents | 21,356 | 18 | 1 | 0 | 8 |
| LangGraph：Persistence | 3,859 | 9 | 3 | 1 | 0 |
| SQLite FTS5 长文对照 | 159,906 | 83 | 111 | 10 | 3 |

两篇用户样本的标题锚点、必要结构和原生转换检查通过；
所有 12 个输入上的代码空白、表格结构、可见文字链接 target 与原生段落区间检查通过。
这不是对复杂公式、所有 SVG 或合并单元格的支持声明。
SQLite 样本仍有不支持媒体诊断，如实报告，不能显示“全部内容完整保存”。

## 4. 截图暴露的缺陷及修复

### 4.1 网站附属信息混入正文

用户截图中的 Topics、主题标签、Related articles 与装饰 SVG 不应作为正文展示。
原型清理现已：

- 文章 header 保留主标题及语义摘要/图文，移除元数据标签菜单。
- 移除推荐 aside，保留明确标注的 note/tip/warning 提示。
- 忽略没有语义标签的小型 SVG 图标；有意义且暂不支持的嵌入内容继续报告，
  不为消除提示而盲目删除全部媒体。
- 不把初始 `visibility:hidden` 动画样式等同于无正文；否则会误删 Anthropic 的标题
  和致谢。明确 hidden / aria-hidden / display:none 仍有对应处理。
- 不把 `sidebar-visible` 页面状态 class 当成整个文档都是侧栏。

以上均有命名回归，不依赖硬编码这两个站点的类名。

### 4.2 列表内链接末尾样式/点击范围提前结束

确认根阅读器在两处重复扣除列表符号长度，导致完整链接末尾落在样式/点击范围外。
`epub_renderer_view.dart` 的 helper 改为返回 fragment 原坐标，统一在消费处扣一次 marker。
不修改原文字串、持久化 locator 或已有 EPUB/PDF/Markdown 数据。

新增 `test/renderers/epub/epub_list_inline_test.dart`：
连续/分页 × 无序/多位有序列表共 4 项，验证完整字符样式和点击事件。
修前 4 FAIL，修后均纳入 164 PASS 的 EPUB/Markdown 回归。

## 5. 性能实验

Linux x86_64，Intel Core Ultra 9 285H，Dart 3.12.2；
使用支持 native hooks 的 `dart build cli` 构建 AOT 工具。
每个候选、每份输入运行 1 次初次调用 + 30 次重复，网络耗时不在其中。

| 样本 | 语义提取热 p50 | 热 p95 | 原生转换单次 |
| --- | --- | --- | --- |
| Anthropic | 13.448 ms | 26.996 ms | 0.974 ms |
| LangGraph | 12.578 ms | 26.038 ms | 0.505 ms |
| SQLite FTS5 | 205.842 ms | 238.203 ms | 11.077 ms |

整个多候选评测进程峰值 RSS 约 190.4 MiB，不是单页或应用整体内存，
也不是每份输入独立测出的内存上限。初次调用与 p95 不代表网络获取或实际首屏时间。
SQLite 规模仍需在后续阶段移出 UI isolate 并验证取消/资源预算，
不能据此宣称整个应用已无卡顿。

## 6. 验证与证据

本地证据根：`.local-data/validation/web-collections-2026-11-26/`。

| 证据 | 结果 |
| --- | --- |
| `tests-closed.log` | 隔离原型 57 PASS，含两篇用户样本的亮暗离屏装载 |
| `analyze-closed.log` | 原型静态分析无问题 |
| `closed-aot/report.json`、`evaluation-closed-aot.log` | 30 次 AOT 对照，selectedGatePass 为 true，退出 0 |
| `negative-gate.log` | 注入样本获取失败后 report 为 false、退出 1，未被记成通过 |
| `list-inline-before.log` | 新增列表链接用例修前 4 FAIL |
| `renderer-regression.log` | 164 PASS / 1 SKIP；跳过的外部样本项不记作实测 |
| `flutter-analyze.log` | 根项目分析无问题 |
| `install-linux.log`、`install-diff.log`、`install-sha256.log` | Linux 重建安装成功，完整 bundle 与 libapp 校验一致 |
| `captures/` | 指定两篇原型的亮/暗截图；已检查正文清理及代码字体 |

首次实验还暴露了回退抽取丢标题、表格内代码与代码内链接丢失；
修复后的最终报告才用于上述结论。早期失败保留，不用挑选的成功日志覆盖失败事实。
截图早期使用测试默认等宽字体出现方格，已显式加载真实等宽字体，
不把测试字体缺失误判为网页编码问题。

应用安装证据另见实施计划；没有打开应用新窗口或重启用户现有进程。
Windows/Android 未运行本轮原型/窗口验收。
