import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:reader_mode/reader_mode.dart' as readability;
import 'package:xml/xml.dart';

enum ExtractionStrategy { readerMode, readerModeJsdom, semantic }

enum ExtractionFailure { empty, challenge, login, dynamicPage, extractorError }

enum ArticleWarning { unsupportedMedia, unsupportedImage, missingImageSource }

final class ArticleImage {
  const ArticleImage({required this.url, required this.localPath});

  final Uri url;
  final String localPath;
}

final class ArticleExtraction {
  ArticleExtraction({
    required this.title,
    required this.xhtml,
    required this.text,
    required List<ArticleImage> images,
    required Set<ArticleWarning> warnings,
    this.failure,
  }) : images = List.unmodifiable(images),
       warnings = Set.unmodifiable(warnings);

  factory ArticleExtraction.rejected(ExtractionFailure reason) {
    return ArticleExtraction(
      title: '',
      xhtml: '',
      text: '',
      images: const [],
      warnings: const {},
      failure: reason,
    );
  }

  final String title;
  final String xhtml;
  final String text;
  final List<ArticleImage> images;
  final Set<ArticleWarning> warnings;
  final ExtractionFailure? failure;

  bool get isReadable => failure == null;
}

final class ArticleExtractor {
  const ArticleExtractor();

  static const version = 2;

  ArticleExtraction extract({
    required String source,
    required Uri pageUrl,
    ExtractionStrategy strategy = ExtractionStrategy.semantic,
  }) {
    if (!_isWebUrl(pageUrl)) {
      throw ArgumentError.value(pageUrl, 'pageUrl', '需要 HTTP/HTTPS 网址');
    }
    if (utf8.encode(source).length > 10 * 1024 * 1024) {
      throw const FormatException('网页超过 10 MiB 提取预算');
    }
    final document = html.parse(source);
    _checkDomBudget(document);
    final title =
        [
              document.querySelector('title')?.text,
              document
                  .querySelector('meta[property="og:title"]')
                  ?.attributes['content'],
              document.querySelector('h1')?.text,
              pageUrl.host,
            ]
            .whereType<String>()
            .map(_headingText)
            .firstWhere((candidate) => candidate.isNotEmpty);
    final body = document.body;
    if (body == null) {
      return ArticleExtraction.rejected(ExtractionFailure.empty);
    }
    final base = document.querySelector('base[href]')?.attributes['href'];
    final baseUrl = base == null ? pageUrl : _resolve(pageUrl, base) ?? pageUrl;
    final hasPassword = body.querySelector('input[type="password"]') != null;
    final hasScripts = document.querySelector('script') != null;
    for (final element
        in document
            .querySelectorAll(
              'script, style, template, noscript, nav, aside, footer',
            )
            .toList()) {
      final articleNote =
          element.localName == 'aside' &&
          (element.attributes['role'] == 'note' ||
              RegExp(
                r'(?:^|\s)(?:note|tip|warning|notecard)(?:$|\s)',
              ).hasMatch(element.className));
      if (articleNote ||
          (element.localName == 'footer' &&
              _hasAncestor(element, const {'article'}))) {
        continue;
      }
      element.remove();
    }
    for (final element in document.querySelectorAll('*').toList()) {
      final role = element.attributes['role'];
      final marker = '${element.id} ${element.className}';
      final style = element.attributes['style'] ?? '';
      final inlineHidden = RegExp(
        r'(?:^|[;\s])display\s*:\s*none',
        caseSensitive: false,
      ).hasMatch(style);
      if (element.attributes.containsKey('hidden') ||
          element.attributes['aria-hidden'] == 'true' ||
          inlineHidden ||
          role == 'navigation' ||
          role == 'complementary' ||
          _noiseMarker.hasMatch(marker)) {
        element.remove();
      }
    }
    final visibleText = body.text.trim();
    if (visibleText.length < 1500 &&
        _challengeTitle.hasMatch(
          '$title ${body.querySelector('h1')?.text ?? ''}'.trim(),
        )) {
      return ArticleExtraction.rejected(ExtractionFailure.challenge);
    }
    final semanticRoot = _semanticRoot(document);
    if (hasPassword &&
        (semanticRoot == null || semanticRoot.querySelectorAll('p').isEmpty)) {
      return ArticleExtraction.rejected(ExtractionFailure.login);
    }
    for (final form in document.querySelectorAll('form').toList()) {
      form.remove();
    }
    for (final header in document.querySelectorAll(
      'article header, main header',
    )) {
      final heading = header.querySelector('h1');
      if (heading == null) {
        continue;
      }
      final kept = <dom.Node>[heading.clone(true)];
      for (final node in header.querySelectorAll('p, figure, picture, img')) {
        var parent = node.parent;
        var nested = false;
        while (parent != null && !identical(parent, header)) {
          if (const {'p', 'figure', 'picture'}.contains(parent.localName)) {
            nested = true;
            break;
          }
          parent = parent.parent;
        }
        if (!nested) {
          kept.add(node.clone(true));
        }
      }
      header.nodes
        ..clear()
        ..addAll(kept);
    }
    if (body.text.trim().isEmpty && body.querySelector('img') == null) {
      return ArticleExtraction.rejected(
        hasScripts ? ExtractionFailure.dynamicPage : ExtractionFailure.empty,
      );
    }
    final String content;
    if (strategy == ExtractionStrategy.semantic && semanticRoot != null) {
      content = semanticRoot.outerHtml;
    } else {
      try {
        final article = readability.parse(
          document.outerHtml,
          parser: strategy == ExtractionStrategy.readerModeJsdom
              ? readability.ParserType.jsdom
              : readability.ParserType.html,
          baseUri: pageUrl.toString(),
          charThreshold: 0,
          maxElemsToParse: 20000,
        );
        if (article == null) {
          return ArticleExtraction.rejected(ExtractionFailure.empty);
        }
        content = article.content;
      } on Object {
        return ArticleExtraction.rejected(ExtractionFailure.extractorError);
      }
    }
    final selected = html.parseFragment(content);
    final mainHeading = semanticRoot
        ?.querySelectorAll('h1')
        .where((heading) => _headingText(heading.text).isNotEmpty)
        .firstOrNull;
    final originalHeading =
        mainHeading ??
        body.querySelectorAll('h1, h2').where((heading) {
          final text = _headingText(heading.text).toLowerCase();
          return text.isNotEmpty && title.toLowerCase().startsWith(text);
        }).firstOrNull;
    if (originalHeading != null &&
        selected
            .querySelectorAll('h1')
            .every((heading) => _headingText(heading.text).isEmpty) &&
        !selected
            .querySelectorAll('h1, h2')
            .any(
              (heading) =>
                  _headingText(heading.text) ==
                  _headingText(originalHeading.text),
            )) {
      selected.nodes.insert(
        0,
        html.parseFragment(originalHeading.outerHtml).nodes.first,
      );
    }
    final sanitizer = _ArticleSanitizer(baseUrl);
    final children = <XmlNode>[
      for (final node in selected.nodes) ...sanitizer.convert(node),
    ];
    final articleBody = XmlElement(XmlName('body'), const [], children);
    if (articleBody.innerText.trim().isEmpty &&
        articleBody.findAllElements('img').isEmpty) {
      return ArticleExtraction.rejected(ExtractionFailure.empty);
    }
    final articleTitle =
        articleBody
            .findAllElements('h1')
            .map((heading) => _headingText(heading.innerText))
            .where((text) => text.isNotEmpty)
            .firstOrNull ??
        title;
    final result = XmlElement(XmlName('html'), const [], [
      XmlElement(XmlName('head'), const [], [
        XmlElement(XmlName('title'), const [], [XmlText(articleTitle)]),
      ]),
      articleBody,
    ]);
    return ArticleExtraction(
      title: articleTitle,
      xhtml: result.toXmlString(),
      text: articleBody.innerText,
      images: sanitizer.images.values.toList(),
      warnings: sanitizer.warnings,
    );
  }

  dom.Element? _semanticRoot(dom.Document document) {
    final main = document.querySelector('main, [role="main"]');
    final articles = (main ?? document).querySelectorAll('article');
    if (articles.isNotEmpty) {
      final ranked = articles.toList()
        ..sort(
          (first, second) => second.text.length.compareTo(first.text.length),
        );
      final best = ranked.first;
      if (main == null || best.text.length >= main.text.length * 0.65) {
        return best;
      }
    }
    return main;
  }
}

final _noiseMarker = RegExp(
  r'(?:^|\s)(?:sidebar|breadcrumb|breadcrumbs|toc|pagination|newsletter|'
  r'advertisement|comments|related|cookie-banner|social-share)(?:$|\s)',
  caseSensitive: false,
);

final _challengeTitle = RegExp(
  r'just a moment|access denied|verify (?:that )?you are human|'
  r'checking your browser|请完成验证|安全验证|访问被拒绝',
  caseSensitive: false,
);

bool _isWebUrl(Uri uri) {
  return (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

void _checkDomBudget(dom.Node root) {
  final pending = <({dom.Node node, int depth})>[(node: root, depth: 0)];
  var elements = 0;
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (current.depth > 128) {
      throw const FormatException('网页嵌套超过提取预算');
    }
    if (current.node is dom.Element) {
      elements += 1;
      if (elements > 20000) {
        throw const FormatException('网页节点超过提取预算');
      }
    }
    for (final child in current.node.nodes) {
      pending.add((node: child, depth: current.depth + 1));
    }
  }
}

bool _hasAncestor(dom.Element element, Set<String> names) {
  var parent = element.parent;
  while (parent != null) {
    if (names.contains(parent.localName)) {
      return true;
    }
    parent = parent.parent;
  }
  return false;
}

Uri? _resolve(Uri base, String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) {
    return null;
  }
  final resolved = base.resolveUri(parsed);
  return _isWebUrl(resolved) ? resolved : null;
}

String _cleanText(String value) {
  return String.fromCharCodes(
    value.runes.where(
      (point) =>
          point == 9 ||
          point == 10 ||
          point == 13 ||
          (point >= 0x20 && point <= 0xd7ff) ||
          (point >= 0xe000 && point <= 0xfffd) ||
          (point >= 0x10000 && point <= 0x10ffff),
    ),
  );
}

String _headingText(String value) =>
    _cleanText(value).replaceAll(RegExp(r'\s+'), ' ').trim();

final class _ArticleSanitizer {
  _ArticleSanitizer(this.baseUrl);

  final Uri baseUrl;
  final Map<String, ArticleImage> images = {};
  final Set<ArticleWarning> warnings = {};

  static const _allowed = {
    'article',
    'section',
    'div',
    'p',
    'span',
    'header',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'li',
    'dl',
    'dt',
    'dd',
    'blockquote',
    'pre',
    'code',
    'br',
    'hr',
    'strong',
    'em',
    'b',
    'i',
    'u',
    's',
    'del',
    'mark',
    'sup',
    'sub',
    'table',
    'thead',
    'tbody',
    'tfoot',
    'tr',
    'td',
    'th',
    'caption',
    'figure',
    'figcaption',
    'a',
    'details',
    'summary',
  };

  Iterable<XmlNode> convert(dom.Node node) sync* {
    if (node is dom.Text) {
      yield XmlText(_cleanText(node.data));
      return;
    }
    if (node is! dom.Element) {
      return;
    }
    final tag = node.localName ?? '';
    if (RegExp(r'^h[1-6]$').hasMatch(tag) && _headingText(node.text).isEmpty) {
      return;
    }
    if (const {
      'script',
      'style',
      'template',
      'form',
      'input',
      'button',
      'link',
      'meta',
      'base',
      'object',
      'embed',
      'source',
    }.contains(tag)) {
      return;
    }
    if (const {
      'iframe',
      'video',
      'audio',
      'canvas',
      'svg',
      'math',
    }.contains(tag)) {
      final width = double.tryParse(node.attributes['width'] ?? '');
      final height = double.tryParse(node.attributes['height'] ?? '');
      if (tag == 'svg' &&
          width != null &&
          height != null &&
          width <= 32 &&
          height <= 32 &&
          node.attributes['aria-label'] == null &&
          node.querySelector('title') == null) {
        return;
      }
      warnings.add(ArticleWarning.unsupportedMedia);
      final label = _cleanText(
        node.attributes['aria-label'] ??
            node.querySelector('title, annotation')?.text ??
            '不支持的嵌入内容',
      );
      yield XmlElement(XmlName('p'), const [], [XmlText('[$label]')]);
      return;
    }
    if (tag == 'img') {
      final url = _imageUrl(node);
      if (url == null) {
        warnings.add(ArticleWarning.missingImageSource);
        yield XmlElement(XmlName('p'), const [], [
          XmlText('[图片未保存：${_cleanText(node.attributes['alt'] ?? '无来源地址')}]'),
        ]);
        return;
      }
      final path = 'resources/${sha256.convert(utf8.encode(url.toString()))}';
      if (images.length >= 256 && !images.containsKey(path)) {
        warnings.add(ArticleWarning.unsupportedImage);
        yield XmlElement(XmlName('p'), const [], [XmlText('[图片未保存：超过数量限制]')]);
        return;
      }
      images.putIfAbsent(path, () => ArticleImage(url: url, localPath: path));
      yield XmlElement(XmlName('img'), [
        XmlAttribute(XmlName('src'), path),
        if (node.attributes['alt'] case final String alt)
          XmlAttribute(XmlName('alt'), _cleanText(alt)),
      ]);
      return;
    }
    final children = <XmlNode>[
      for (final child in node.nodes) ...convert(child),
    ];
    if (!_allowed.contains(tag)) {
      yield* children;
      return;
    }
    final attributes = <XmlAttribute>[
      if (node.attributes['id'] case final String id)
        XmlAttribute(XmlName('id'), _cleanText(id)),
    ];
    if (tag == 'a') {
      final value = node.attributes['href'];
      if (value != null) {
        final resolved = _resolve(baseUrl, value);
        if (value.startsWith('#')) {
          attributes.add(XmlAttribute(XmlName('href'), _cleanText(value)));
        } else if (resolved != null) {
          attributes.add(XmlAttribute(XmlName('href'), resolved.toString()));
        }
      }
    }
    if (tag == 'td' || tag == 'th') {
      for (final name in ['colspan', 'rowspan']) {
        final value = int.tryParse(node.attributes[name] ?? '');
        if (value != null && value >= 1 && value <= 100) {
          attributes.add(XmlAttribute(XmlName(name), value.toString()));
        }
      }
    }
    yield XmlElement(XmlName(tag), attributes, children);
  }

  Uri? _imageUrl(dom.Element element) {
    final srcset =
        element.attributes['data-srcset'] ?? element.attributes['srcset'];
    if (srcset != null) {
      final choices = <({Uri url, double scale})>[];
      for (final entry in srcset.split(',')) {
        final parts = entry.trim().split(RegExp(r'\s+'));
        final url = _resolve(baseUrl, parts.first);
        if (url == null) {
          continue;
        }
        var scale = 1.0;
        if (parts.length > 1) {
          final descriptor = parts.last;
          if (!RegExp(r'^\d+(?:\.\d+)?[wx]$').hasMatch(descriptor)) {
            continue;
          }
          final size = double.parse(
            descriptor.substring(0, descriptor.length - 1),
          );
          scale = descriptor.endsWith('w') ? size / 800 : size;
        }
        if (scale > 0 && scale.isFinite) {
          choices.add((url: url, scale: scale));
        }
      }
      choices.sort((first, second) => first.scale.compareTo(second.scale));
      final bounded = choices.where((choice) => choice.scale <= 2).toList();
      if (bounded.isNotEmpty) {
        return bounded.last.url;
      }
      if (choices.isNotEmpty) {
        return choices.first.url;
      }
    }
    for (final key in ['data-src', 'data-original', 'src']) {
      final value = element.attributes[key];
      if (value != null) {
        final url = _resolve(baseUrl, value);
        if (url != null) {
          return url;
        }
      }
    }
    return null;
  }
}
