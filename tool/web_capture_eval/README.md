# 网页抽取与原生阅读原型

这是网页合集 W0 的**隔离评测工具**，不是应用入口，不连接用户数据库。
抽取器与原生转换器已迁入根项目生产代码，本工具的同名入口 re-export 正式实现，
继续保留独立输入、评测与对照；正式应用不依赖 Python 评测脚本。
需求与后续阶段见[网页合集规格](../../docs/specs/web-collections-2026-11-26/README.md)。

## 比较内容

- `readerMode`：reader_mode 0.2.3 的 HTML adapter。
- `readerModeJsdom`：同一版本的纯 Dart JSDOM adapter。
- `semantic`：优先保留文章/main 语义区域，缺少结构时回退 HTML adapter。

三者使用相同的输入预算、预清理和输出白名单。这里的库配置不等于官方
Mozilla JavaScript 版本的结果，也不把纯 Dart JSDOM adapter 误称为浏览器运行时。
固定版本、解析配置和公共检查项均可复现，不能把结果推广到所有站点。

`native_html_parser.dart` 把安全 XHTML 转成现有 `EpubDocument` / block 模型，
保留代码空白、表格单元格、内联样式、链接、大纲与 UTF-16 区间；
同时保留旧 `EpubChapterParser` 对照，报告直接复用旧转换的结构损失。
没有另建绘制引擎，也没有修改现有 EPUB/Markdown 的生产解析行为。

## 运行

在本目录执行：

```bash
flutter pub get
flutter test test/article_extractor_test.dart test/evaluation_test.dart test/native_article_test.dart --concurrency=4 --reporter expanded
dart analyze lib bin test
```

24 个冻结自建 HTML 用例及其人工预期保存在 `fixtures/cases.json`。
文字保留率按去空白后完整金标片段的 Unicode scalar 数计；同一匹配不能重复计分。
未与金标匹配的输出字符计入杂质。该度量较严格，不是模糊语义相似度。
原生转换另查结构和真实区间，不用去空白评分掩盖代码缩进问题。
提取器自身异常不能算“正确拒绝不支持页面”。

获取真实网页（需要网络和 Python 3 标准库）：

```bash
python3 fetch_samples.py --output ../../.local-data/validation/web-collections-2026-11-26/public-pages
dart run bin/evaluate.dart --output ../../.local-data/validation/web-collections-2026-11-26/report --samples ../../.local-data/validation/web-collections-2026-11-26/public-pages --iterations 30
```

已存在 manifest 的目录默认拒绝覆盖，需换新目录或显式 `--refresh`。
真实网页、输出 XHTML 和报告放在被忽略的本地目录，不进入公开语料。
`public-sources.json` 是来源清单；`public-checks.json` 是人工检查的标题锚点和结构下限。
后者是冒烟检查，**不是完整正文金标**，不能以它宣称真实网页正文保留率 100%。
报告同时给出冷调用、热循环 p50/p95 和整个进程的 RSS/峰值；不是每页独立峰值。
选定策略有夹具、真实样本或原生结构失败时，命令返回非零。

可构建 Linux AOT 评测 bundle 后，用其中的可执行文件和同样参数评测，
避免只报告 JIT 热身结果。隔离包引用现有 PageSage 模型，依赖树带有原项目的
native build hooks，因此使用支持 hooks 的入口：

```bash
dart build cli --target bin/evaluate.dart --output ../../.local-data/validation/web-collections-2026-11-26/eval-cli
```

## 离屏检查

设置 `PAGESAGE_WEB_CAPTURE_DIR` 可输出亮暗截图；设置 `PAGESAGE_WEB_SAMPLES_DIR`
指向上述样本目录时，还会装载用户提供的 Anthropic 和 LangGraph 页面。
截图需将 `PAGESAGE_WEB_MONO_FONT` 指向本机可读取的等宽 TTF 文件，
避免 Flutter 测试字体把代码绘成方格。图片资源尚未下载时显示明确占位。
截图和字体加载都在无窗口 widget 测试中执行。

## 结果边界

- 验证正文抽取、资源引用解析、原生模型转换和指定尺寸离屏阅读。
- 应用已实现图片下载、快照落盘、合集、刷新、迁移及备份，见
  [首版记录](../../docs/specs/web-collections-2026-11-26/07-implementation.md)；
  本工具结果只证明抽取与原生转换，不代替应用链路验收。
- 不证明登录页面、动态交互、复杂公式、跨行/跨列表格或音视频完整可读。
- reader_mode 核心与 JSDOM 文件的许可分别涉及 Apache-2.0 / MPL-2.0；
  接入应用前需按实际采用文件核对并补充第三方声明，不只依据包主页的简写。
- 工具使用 Python 获取测试输入；未来应用的获取与解析路径不因此依赖 Python。
