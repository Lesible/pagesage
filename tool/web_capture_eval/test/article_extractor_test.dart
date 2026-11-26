import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage_web_capture_eval/article_extractor.dart';
import 'package:pagesage_web_capture_eval/evaluation.dart';
import 'package:xml/xml.dart';

void main() {
  final fixtures =
      (jsonDecode(File('fixtures/cases.json').readAsStringSync())
              as List<Object?>)
          .cast<Map<String, Object?>>();
  const extractor = ArticleExtractor();
  final pageUrl = Uri.parse('https://example.test/articles/page.html');

  for (final fixture in fixtures) {
    test('semantic extraction: ${fixture['id']}', () {
      final result = extractor.extract(
        source: fixture['html']! as String,
        pageUrl: pageUrl,
      );
      final score = scoreExtraction(
        result,
        expected: (fixture['expected']! as List<Object?>).cast<String>(),
        shouldReject: fixture['reject'] == true,
      );
      expect(
        score.passes,
        isTrue,
        reason:
            'recall=${score.retention}, noise=${score.noise}, '
            'failure=${result.failure}, text=${result.text}',
      );
      if (fixture['imageUrls'] case final List<Object?> urls) {
        expect(
          result.images.map((image) => image.url.toString()).toList(),
          urls,
        );
      }
      if (fixture['warning'] case final String warning) {
        expect(result.warnings.map((value) => value.name), contains(warning));
      }
      if (!result.isReadable) {
        expect(result.failure!.name, fixture['rejectReason']);
        return;
      }
      final xml = XmlDocument.parse(result.xhtml);
      expect(xml.findAllElements('script'), isEmpty);
      expect(xml.findAllElements('style'), isEmpty);
      expect(xml.findAllElements('iframe'), isEmpty);
      for (final element in xml.descendants.whereType<XmlElement>()) {
        expect(
          element.attributes.where(
            (attribute) =>
                attribute.name.local.startsWith('on') ||
                attribute.name.local == 'style',
          ),
          isEmpty,
        );
      }
      for (final image in xml.findAllElements('img')) {
        expect(image.getAttribute('src'), startsWith('resources/'));
        expect(image.getAttribute('src'), isNot(contains('..')));
      }
    });
  }

  test('relative and meaningful query links remain links', () {
    final result = extractor.extract(
      source:
          fixtures.firstWhere(
                (value) => value['id'] == 'meaningful-query',
              )['html']!
              as String,
      pageUrl: pageUrl,
    );
    final xml = XmlDocument.parse(result.xhtml);
    expect(
      xml.findAllElements('a').single.getAttribute('href'),
      'https://example.test/articles/page.html?version=2&lang=zh#section',
    );
    expect(result.images, hasLength(1));
  });

  test('dangerous URLs, base and control characters do not survive', () {
    final result = extractor.extract(
      source: '''
<base href="javascript:attack()"><article><h1>safe</h1>
<p>left\u0001right <a href="data:text/html,attack">label</a></p>
<img src="file:///etc/passwd" alt="blocked">
<img src="https://user:password@example.test/private" alt="private">
</article>''',
      pageUrl: pageUrl,
    );
    expect(result.xhtml, isNot(contains('javascript:')));
    expect(result.xhtml, isNot(contains('data:text')));
    expect(result.xhtml, isNot(contains('file:')));
    expect(result.xhtml, isNot(contains('password')));
    expect(result.text, contains('leftright'));
    expect(result.images, isEmpty);
    expect(result.warnings, contains(ArticleWarning.missingImageSource));
    expect(() => XmlDocument.parse(result.xhtml), returnsNormally);
  });

  test('short article with login discussion is not a login wall', () {
    final result = extractor.extract(
      source:
          '<article><h1>Login design</h1><p>Explain safe login.</p>'
          '<form><input type="password"></form></article>',
      pageUrl: pageUrl,
    );
    expect(result.isReadable, isTrue);
    expect(result.text, contains('Explain safe login.'));
  });

  test('source addresses are explicit HTTP/HTTPS without credentials', () {
    for (final value in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'https://user:password@example.test',
    ]) {
      expect(
        () =>
            extractor.extract(source: '<p>Text</p>', pageUrl: Uri.parse(value)),
        throwsArgumentError,
      );
    }
  });

  test('sidebar visibility state on the page shell does not erase content', () {
    final result = extractor.extract(
      source:
          '<html class="sidebar-visible"><body class="sidebar-open">'
          '<main><h1>Chapter</h1><p>Keep this article.</p></main></body></html>',
      pageUrl: pageUrl,
    );
    expect(result.isReadable, isTrue);
    expect(result.text, contains('Keep this article.'));
  });

  test('article heading outside the article body is retained once', () {
    final result = extractor.extract(
      source:
          '<title>Chapter | Site</title><main><header><h1>Chapter</h1>'
          '</header><article><p>${'Useful content. ' * 25}</p></article></main>',
      pageUrl: pageUrl,
    );
    final xml = XmlDocument.parse(result.xhtml);
    expect(xml.findAllElements('h1').single.innerText, 'Chapter');
  });

  test('article metadata, related panels and tiny icons are not body', () {
    final result = extractor.extract(
      source:
          '<main><article><header><h1>Article</h1>'
          '<div>Topics</div><ul><li><a href="/tag">Tag</a></li></ul>'
          '</header><p>Real body.</p>'
          '<aside><div>Related articles</div><a href="/other">Other</a></aside>'
          '<svg width="12" height="12"><path d="M0 0"/></svg>'
          '<aside role="note"><p>Important note.</p></aside></article></main>',
      pageUrl: pageUrl,
    );
    expect(result.text, contains('Article'));
    expect(result.text, contains('Real body.'));
    expect(result.text, contains('Important note.'));
    expect(result.text, isNot(contains('Topics')));
    expect(result.text, isNot(contains('Related articles')));
    expect(result.text, isNot(contains('不支持的嵌入内容')));
  });

  test('matching h2 article title survives legacy readability fallback', () {
    final result = extractor.extract(
      source:
          '<title>A release | Site</title><h2>A release</h2>'
          '<div><p>${'Release details are useful. ' * 25}</p></div>',
      pageUrl: pageUrl,
    );
    expect(result.text, contains('A release'));
  });

  test(
    'animated article heading and article footnotes are not boilerplate',
    () {
      final result = extractor.extract(
        source:
            '<main><article><header style="visibility:hidden">'
            '<h1>Animated heading</h1></header><p>Body.</p>'
            '<footer><p>Footnote one.</p></footer></article></main>',
        pageUrl: pageUrl,
      );
      expect(result.text, contains('Animated heading'));
      expect(result.text, contains('Footnote one.'));
      expect(result.xhtml, isNot(contains('visibility')));
    },
  );

  test('byte and element budgets reject excessive input', () {
    expect(
      () =>
          extractor.extract(source: '中' * (4 * 1024 * 1024), pageUrl: pageUrl),
      throwsFormatException,
    );
    expect(
      () => extractor.extract(
        source: '<main>${'<span>x</span>' * 20001}</main>',
        pageUrl: pageUrl,
      ),
      throwsFormatException,
    );
    expect(
      () => extractor.extract(
        source: '<main>${'<span>' * 150}text${'</span>' * 150}</main>',
        pageUrl: pageUrl,
      ),
      throwsFormatException,
    );
  });

  test('image quantity is bounded without dropping the article', () {
    final result = extractor.extract(
      source:
          '<article><p>Images.</p>${List.generate(257, (index) => '<img src="/image-$index.png">').join()}</article>',
      pageUrl: pageUrl,
    );
    expect(result.isReadable, isTrue);
    expect(result.images, hasLength(256));
    expect(result.warnings, contains(ArticleWarning.unsupportedImage));
    expect(result.text, contains('超过数量限制'));
  });

  test('extraction is deterministic and returns immutable collections', () {
    final fixture = fixtures.firstWhere((value) => value['id'] == 'lazy-image');
    final first = extractor.extract(
      source: fixture['html']! as String,
      pageUrl: pageUrl,
    );
    final second = extractor.extract(
      source: fixture['html']! as String,
      pageUrl: pageUrl,
    );
    expect(first.xhtml, second.xhtml);
    expect(() => first.images.clear(), throwsUnsupportedError);
    expect(() => first.warnings.clear(), throwsUnsupportedError);
  });
}
