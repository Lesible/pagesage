import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage_web_capture_eval/article_extractor.dart';
import 'package:pagesage_web_capture_eval/evaluation.dart';

void main() {
  ArticleExtraction article(String text) {
    return ArticleExtraction(
      title: '',
      xhtml: '',
      text: text,
      images: const [],
      warnings: const {},
    );
  }

  test('score penalizes missing text and boilerplate independently', () {
    final result = scoreExtraction(article('正文一广告'), expected: ['正文一', '正文二']);
    expect(result.retention, 0.5);
    expect(result.noise, 0.4);
    expect(result.passes, isFalse);
  });

  test('the same match cannot satisfy duplicate expected fragments', () {
    final result = scoreExtraction(article('示例'), expected: ['示例', '示例']);
    expect(result.retention, 0.5);
  });

  test('emoji and combining characters are scored as Unicode scalars', () {
    final result = scoreExtraction(
      article('📚 café\n'),
      expected: ['📚', 'café'],
    );
    expect(result.retention, 1);
    expect(result.noise, 0);
  });

  test('an empty successful result does not earn a quality pass', () {
    expect(scoreExtraction(article(''), expected: []).passes, isFalse);
  });

  test('incorrect acceptance and incorrect rejection both fail', () {
    expect(
      scoreExtraction(
        article('Login'),
        expected: [],
        shouldReject: true,
      ).passes,
      isFalse,
    );
    expect(
      scoreExtraction(
        ArticleExtraction.rejected(ExtractionFailure.empty),
        expected: ['short article'],
      ).passes,
      isFalse,
    );
    expect(
      scoreExtraction(
        ArticleExtraction.rejected(ExtractionFailure.extractorError),
        expected: [],
        shouldReject: true,
      ).passes,
      isFalse,
    );
  });
}
