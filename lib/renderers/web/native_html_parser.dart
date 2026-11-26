import 'dart:typed_data';

import 'package:pagesage/renderers/common/image_size.dart';
import 'package:pagesage/renderers/epub/epub_chapter_parser.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';
import 'package:xml/xml.dart';

import '../../features/web_books/data/article_extractor.dart';

final class NativeHtmlParser {
  NativeHtmlParser({required this.imageBytes});

  final Map<String, Uint8List> imageBytes;

  EpubDocument parse(ArticleExtraction article) {
    final body = XmlDocument.parse(
      article.xhtml,
    ).findAllElements('body').single;
    final builder = _DocumentBuilder(imageBytes);
    builder.visit(body);
    builder.flush();
    return EpubDocument(
      chapters: [
        EpubChapter(
          index: 0,
          href: 'article.xhtml',
          title: article.title,
          text: builder.text.toString(),
          blocks: List.unmodifiable(builder.blocks),
          anchors: Map.unmodifiable(builder.anchors),
        ),
      ],
      toc: _outline(builder.blocks),
    );
  }
}

final class _DocumentBuilder {
  _DocumentBuilder(this.imageBytes);

  final Map<String, Uint8List> imageBytes;
  final StringBuffer text = StringBuffer();
  final List<EpubBlock> blocks = [];
  final Map<String, int> anchors = {};
  final List<({bool ordered, int next})> _lists = [];
  _InlineBuffer _inline = _InlineBuffer();
  EpubBlockType _kind = EpubBlockType.paragraph;
  int? _heading;
  int _quoteDepth = 0;
  String? _marker;
  int _listIndent = 0;

  void visit(XmlNode node, [Map<EpubInlineStyle, String?> styles = const {}]) {
    if (node is XmlText) {
      _inline.append(node.value, styles);
      return;
    }
    if (node is! XmlElement) {
      return;
    }
    final tag = node.name.local;
    if (tag == 'img') {
      flush();
      blocks.add(
        EpubImageBlock(
          startOffset: text.length,
          image: _image(node),
          quoteDepth: _quoteDepth,
        ),
      );
      return;
    }
    if (tag == 'hr') {
      flush();
      blocks.add(
        EpubDividerBlock(startOffset: text.length, quoteDepth: _quoteDepth),
      );
      return;
    }
    if (tag == 'br') {
      _inline.append('\u2028', styles);
      return;
    }
    if (tag == 'table') {
      _table(node);
      return;
    }
    if (tag == 'pre') {
      flush();
      final previous = _kind;
      _kind = EpubBlockType.code;
      _mark(node);
      _collectInline(node, _inline, const {}, preserveWhitespace: true);
      flush();
      _kind = previous;
      return;
    }
    if (tag == 'blockquote') {
      flush();
      _quoteDepth += 1;
      _mark(node);
      _children(node, styles);
      flush();
      _quoteDepth -= 1;
      return;
    }
    if (tag == 'ul' || tag == 'ol') {
      flush();
      _lists.add((ordered: tag == 'ol', next: 1));
      _mark(node);
      _children(node, styles);
      flush();
      _lists.removeLast();
      return;
    }
    final level = RegExp(r'^h[1-6]$').hasMatch(tag)
        ? int.parse(tag.substring(1))
        : null;
    final isBlock =
        level != null ||
        const {
          'body',
          'article',
          'section',
          'div',
          'header',
          'p',
          'li',
          'pre',
          'figure',
          'figcaption',
          'caption',
          'details',
          'summary',
          'dl',
          'dt',
          'dd',
        }.contains(tag);
    if (isBlock) {
      flush();
      final previousKind = _kind;
      final previousHeading = _heading;
      final previousMarker = _marker;
      final previousIndent = _listIndent;
      _kind = level != null
          ? EpubBlockType.heading
          : tag == 'pre'
          ? EpubBlockType.code
          : (tag == 'figcaption' || tag == 'caption')
          ? EpubBlockType.caption
          : _quoteDepth > 0
          ? EpubBlockType.quote
          : EpubBlockType.paragraph;
      _heading = level;
      _marker = null;
      _listIndent = 0;
      _mark(node);
      if (tag == 'li' && _lists.isNotEmpty) {
        final list = _lists.last;
        _marker = list.ordered ? '${list.next}. ' : '• ';
        _lists[_lists.length - 1] = (
          ordered: list.ordered,
          next: list.next + 1,
        );
        _listIndent = _lists.length - 1;
        _inline.append(_marker!, const {});
      }
      _children(node, styles);
      flush();
      _kind = previousKind;
      _heading = previousHeading;
      _marker = previousMarker;
      _listIndent = previousIndent;
      return;
    }
    _mark(node);
    _children(node, _styles(node, styles));
  }

  void _children(XmlElement node, Map<EpubInlineStyle, String?> styles) {
    for (final child in node.children) {
      visit(child, styles);
    }
  }

  void _mark(XmlElement node) {
    final id = node.getAttribute('id');
    if (id != null && id.isNotEmpty) {
      _inline.marks.putIfAbsent(id, () => _inline.raw.length);
    }
  }

  void flush() {
    final built = _inline.build(
      preserveWhitespace: _kind == EpubBlockType.code,
    );
    final pending = _inline.marks.keys.toList();
    _inline = _InlineBuffer();
    if (built.text.trim().isEmpty) {
      for (final id in pending) {
        _inline.marks[id] = 0;
      }
      return;
    }
    _separator();
    final start = text.length;
    for (final entry in built.anchors.entries) {
      anchors.putIfAbsent(entry.key, () => start + entry.value);
    }
    text.write(built.text);
    blocks.add(
      EpubTextBlock(
        startOffset: start,
        endOffset: text.length,
        text: built.text,
        type: _kind,
        headingLevel: _heading,
        listMarker: _marker,
        listIndent: _listIndent,
        quoteDepth: _quoteDepth,
        runs: List.unmodifiable([
          for (final run in built.runs)
            EpubInlineRun(
              start: start + run.start,
              end: start + run.end,
              style: run.style,
              target: run.target,
            ),
        ]),
      ),
    );
  }

  void _separator() {
    if (text.isNotEmpty) {
      text.write('\n\n');
    }
  }

  void _table(XmlElement table) {
    flush();
    for (final caption in table.findElements('caption')) {
      visit(caption);
    }
    _separator();
    final start = text.length;
    final id = table.getAttribute('id');
    if (id != null) {
      anchors.putIfAbsent(id, () => start);
    }
    final rows = <List<EpubTableCell>>[];
    var header = false;
    for (final row in table.findAllElements('tr')) {
      if (!identical(
        row.ancestors.whereType<XmlElement>().firstWhere(
          (parent) => parent.name.local == 'table',
        ),
        table,
      )) {
        continue;
      }
      final cells = <EpubTableCell>[];
      if (rows.isNotEmpty) {
        text.write('\n');
      }
      for (final cell in row.children.whereType<XmlElement>().where(
        (element) => element.name.local == 'td' || element.name.local == 'th',
      )) {
        if (cells.isNotEmpty) {
          text.write('\t');
        }
        final inline = _InlineBuffer();
        _collectInline(cell, inline, const {});
        final built = inline.build();
        final offset = text.length;
        if (rows.isEmpty && cell.name.local == 'th') {
          header = true;
        }
        cells.add(
          EpubTableCell(
            text: built.text,
            runs: List.unmodifiable(built.runs),
            chapterOffset: offset,
          ),
        );
        for (final mark in built.anchors.entries) {
          anchors.putIfAbsent(mark.key, () => offset + mark.value);
        }
        text.write(built.text);
      }
      if (cells.isNotEmpty) {
        rows.add(cells);
      }
    }
    if (rows.isEmpty) {
      return;
    }
    final width = rows
        .map((row) => row.length)
        .reduce((first, second) => first > second ? first : second);
    blocks.add(
      EpubTableBlock(
        startOffset: start,
        endOffset: text.length,
        text: text.toString().substring(start),
        hasHeader: header,
        quoteDepth: _quoteDepth,
        cells: List.unmodifiable([
          for (final row in rows)
            List<EpubTableCell>.unmodifiable([
              ...row,
              for (var column = row.length; column < width; column += 1)
                const EpubTableCell(text: ''),
            ]),
        ]),
      ),
    );
  }

  EpubImage _image(XmlElement element) {
    final path = element.getAttribute('src') ?? '';
    final bytes = imageBytes[path];
    final size = bytes == null ? null : readImageSize(bytes);
    final String? unavailable;
    if (bytes == null || bytes.isEmpty) {
      unavailable = '图片不在书中';
    } else if (bytes.length > EpubChapterParser.maxImageBytes) {
      unavailable = '图片过大，已跳过';
    } else if (size == null) {
      unavailable = '图片格式无法识别';
    } else if (size.width * size.height > EpubChapterParser.maxImagePixels) {
      unavailable = '图片像素过多，已跳过';
    } else {
      unavailable = null;
    }
    return EpubImage(
      archivePath: path,
      bytes: unavailable == null ? bytes! : Uint8List(0),
      pixelWidth: size?.width ?? 0,
      pixelHeight: size?.height ?? 0,
      alt: element.getAttribute('alt'),
      unavailableReason: unavailable,
    );
  }
}

Map<EpubInlineStyle, String?> _styles(
  XmlElement node,
  Map<EpubInlineStyle, String?> inherited,
) {
  final style = switch (node.name.local) {
    'b' || 'strong' => EpubInlineStyle.strong,
    'i' || 'em' => EpubInlineStyle.emphasis,
    'code' => EpubInlineStyle.code,
    's' || 'del' => EpubInlineStyle.strike,
    'u' => EpubInlineStyle.underline,
    'mark' => EpubInlineStyle.highlight,
    'sub' => EpubInlineStyle.subscript,
    'sup' => EpubInlineStyle.superscript,
    'a' when node.getAttribute('href') != null => EpubInlineStyle.link,
    _ => null,
  };
  return style == null
      ? inherited
      : {...inherited, style: node.getAttribute('href')};
}

void _collectInline(
  XmlNode node,
  _InlineBuffer buffer,
  Map<EpubInlineStyle, String?> styles, {
  bool preserveWhitespace = false,
}) {
  if (node is XmlText) {
    buffer.append(node.value, styles, preserve: preserveWhitespace);
  } else if (node is XmlElement) {
    final id = node.getAttribute('id');
    if (id != null) {
      buffer.marks.putIfAbsent(id, () => buffer.raw.length);
    }
    if (node.name.local == 'br') {
      buffer.append(
        preserveWhitespace ? '\n' : '\u2028',
        styles,
        preserve: preserveWhitespace,
      );
    }
    final pre = preserveWhitespace || node.name.local == 'pre';
    final current = node.name.local == 'pre'
        ? {..._styles(node, styles), EpubInlineStyle.code: null}
        : _styles(node, styles);
    for (final child in node.children) {
      _collectInline(child, buffer, current, preserveWhitespace: pre);
    }
  }
}

final class _InlineBuffer {
  final StringBuffer raw = StringBuffer();
  final List<EpubInlineRun> _runs = [];
  final Map<String, int> marks = {};
  final List<({int start, int end})> _preserved = [];

  void append(
    String value,
    Map<EpubInlineStyle, String?> styles, {
    bool preserve = false,
  }) {
    final start = raw.length;
    raw.write(value);
    if (preserve && value.isNotEmpty) {
      _preserved.add((start: start, end: raw.length));
    }
    for (final entry in styles.entries) {
      _runs.add(
        EpubInlineRun(
          start: start,
          end: raw.length,
          style: entry.key,
          target: entry.value,
        ),
      );
    }
  }

  _InlineResult build({bool preserveWhitespace = false}) {
    final input = raw.toString();
    final output = StringBuffer();
    final positions = List<int>.filled(input.length + 1, 0);
    var lastSpace = true;
    var preservedIndex = 0;
    for (var index = 0; index < input.length; index += 1) {
      positions[index] = output.length;
      while (preservedIndex < _preserved.length &&
          _preserved[preservedIndex].end <= index) {
        preservedIndex += 1;
      }
      final literal =
          preserveWhitespace ||
          (preservedIndex < _preserved.length &&
              _preserved[preservedIndex].start <= index);
      final hardBreak = !literal && input.codeUnitAt(index) == 0x2028;
      final space = !hardBreak && input[index].trim().isEmpty;
      if (literal || !space || !lastSpace) {
        output.write(
          hardBreak
              ? '\n'
              : literal || !space
              ? input[index]
              : ' ',
        );
      }
      lastSpace = space || hardBreak;
    }
    final built = preserveWhitespace
        ? output.toString()
        : output.toString().trimRight();
    positions[input.length] = built.length;
    int offset(int position) => positions[position].clamp(0, built.length);
    return _InlineResult(
      built,
      [
        for (final run in _runs)
          if (offset(run.start) < offset(run.end))
            EpubInlineRun(
              start: offset(run.start),
              end: offset(run.end),
              style: run.style,
              target: run.target,
            ),
      ],
      {for (final entry in marks.entries) entry.key: offset(entry.value)},
    );
  }
}

final class _InlineResult {
  const _InlineResult(this.text, this.runs, this.anchors);

  final String text;
  final List<EpubInlineRun> runs;
  final Map<String, int> anchors;
}

List<EpubTocItem> _outline(List<EpubBlock> blocks) {
  final roots = <_HeadingNode>[];
  final stack = <_HeadingNode>[];
  for (final block in blocks.whereType<EpubTextBlock>()) {
    if (block.type != EpubBlockType.heading) {
      continue;
    }
    final node = _HeadingNode(block);
    while (stack.isNotEmpty &&
        stack.last.block.headingLevel! >= block.headingLevel!) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(node);
    } else {
      stack.last.children.add(node);
    }
    stack.add(node);
  }
  return List.unmodifiable(roots.map((node) => node.build()));
}

final class _HeadingNode {
  _HeadingNode(this.block);

  final EpubTextBlock block;
  final List<_HeadingNode> children = [];

  EpubTocItem build() {
    return EpubTocItem(
      title: block.text,
      href: 'article.xhtml',
      chapterIndex: 0,
      chapterOffset: block.startOffset,
      children: List.unmodifiable(children.map((child) => child.build())),
    );
  }
}
