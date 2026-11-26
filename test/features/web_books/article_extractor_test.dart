import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/features/web_books/data/article_extractor.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';
import 'package:pagesage/renderers/web/native_html_parser.dart';
import 'package:xml/xml.dart';

void main() {
  const extractor = ArticleExtractor();
  final pageUrl = Uri.parse('https://example.test/article');

  test('visible article H1 is the title without site suffix or duplicate', () {
    final article = extractor.extract(
      source: '''
<title>Persistence - Docs by Example</title><main><article>
<h1 id="title">Persistence</h1><p>Introduction.</p>
<h2 id="first">Checkpointing</h2><p>Details.</p>
<h3 id="nested">State</h3><p>Nested details.</p>
<h2 id="second">Stores</h2><p>More details.</p>
</article></main>''',
      pageUrl: pageUrl,
    );
    expect(article.title, 'Persistence');
    final document = NativeHtmlParser(imageBytes: const {}).parse(article);
    expect(document.chapters.single.title, 'Persistence');
    final chapter = document.chapters.single;
    final headings = chapter.blocks.whereType<EpubTextBlock>().where(
      (block) => block.type == EpubBlockType.heading,
    );
    expect(headings.map((block) => block.text), [
      'Persistence',
      'Checkpointing',
      'State',
      'Stores',
    ]);
    for (final block in headings) {
      expect(
        chapter.text.substring(block.startOffset, block.endOffset),
        block.text,
      );
    }
    expect(document.toc.single.children.first.children.single.title, 'State');
  });

  test('empty document title falls back to the article H1', () {
    final article = extractor.extract(
      source:
          '<title> </title><article><h1>Actual title</h1><p>Text.</p></article>',
      pageUrl: pageUrl,
    );
    expect(article.title, 'Actual title');
  });

  test(
    'a different article heading is not promoted into the selected article',
    () {
      final article = extractor.extract(
        source:
            '<title>Actual article | Site</title><main>'
            '<article><h1>Other article</h1><p>Short teaser.</p></article>'
            '<article><p>${'Actual body. ' * 120}</p><h2>Details</h2>'
            '<p>More details.</p></article></main>',
        pageUrl: pageUrl,
      );
      expect(article.title, 'Actual article | Site');
      expect(article.text, isNot(contains('Other article')));
      expect(XmlDocument.parse(article.xhtml).findAllElements('h1'), isEmpty);
    },
  );

  test('animated article header and body headings retain source order', () {
    final article = extractor.extract(
      source: '''
<title>Context engineering | Example</title><main><article>
<header style="visibility:hidden"><h3> </h3>
<h1>Context engineering</h1><div>Category metadata</div></header>
<div data-article-body="true"><p>Introduction.</p>
<h2>Context vs. prompting</h2><p>First section.</p>
<h2>Why context matters</h2><p>Second section.</p></div>
</article></main>''',
      pageUrl: pageUrl,
    );
    expect(article.title, 'Context engineering');
    final xml = XmlDocument.parse(article.xhtml);
    expect(xml.findAllElements('h3'), isEmpty);
    expect(xml.findAllElements('h1').single.innerText, 'Context engineering');
    expect(xml.findAllElements('h2').map((heading) => heading.innerText), [
      'Context vs. prompting',
      'Why context matters',
    ]);
    expect(article.text, isNot(contains('Category metadata')));
  });

  test('a paragraph mentioning an external heading does not replace it', () {
    final article = extractor.extract(
      source:
          '<title>Actual title | Site</title><main>'
          '<header><h1>Actual title</h1></header>'
          '<article><p>Actual title is explained here. ${'Body. ' * 80}</p>'
          '</article></main>',
      pageUrl: pageUrl,
    );
    final xml = XmlDocument.parse(article.xhtml);
    expect(xml.findAllElements('h1').single.innerText, 'Actual title');
  });

  for (final strategy in ExtractionStrategy.values) {
    test('fallback restores the article title for ${strategy.name}', () {
      final article = extractor.extract(
        source:
            '<title>Actual title | Site</title><h1>Actual title</h1>'
            '<div><p>${'Useful long body. ' * 80}</p></div>',
        pageUrl: pageUrl,
        strategy: strategy,
      );
      expect(article.isReadable, isTrue);
      expect(article.title, 'Actual title');
      expect(
        XmlDocument.parse(article.xhtml).findAllElements('h1').single.innerText,
        'Actual title',
      );
    });
  }
}
