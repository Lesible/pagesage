import 'article_extractor.dart';

final class ExtractionScore {
  const ExtractionScore({
    required this.retention,
    required this.noise,
    required this.rejectionCorrect,
  });

  final double retention;
  final double noise;
  final bool rejectionCorrect;

  bool get passes => rejectionCorrect && retention >= 0.95 && noise <= 0.05;
}

ExtractionScore scoreExtraction(
  ArticleExtraction result, {
  required List<String> expected,
  bool shouldReject = false,
}) {
  if (shouldReject) {
    final correct =
        !result.isReadable &&
        result.failure != ExtractionFailure.extractorError;
    return ExtractionScore(
      retention: 1,
      noise: correct ? 0 : 1,
      rejectionCorrect: correct,
    );
  }
  final actual = normalizeForEvaluation(result.text);
  var unmatched = actual;
  var retained = 0;
  var total = 0;
  for (final text in expected) {
    final normalized = normalizeForEvaluation(text);
    if (normalized.isEmpty) {
      throw ArgumentError('金标片段不能为空');
    }
    total += normalized.runes.length;
    final match = unmatched.indexOf(normalized);
    if (match >= 0) {
      retained += normalized.runes.length;
      unmatched = unmatched.replaceRange(match, match + normalized.length, '');
    }
  }
  return ExtractionScore(
    retention: total == 0 ? 0 : retained / total,
    noise: actual.isEmpty ? 1 : unmatched.runes.length / actual.runes.length,
    rejectionCorrect: result.isReadable,
  );
}

String normalizeForEvaluation(String value) {
  return value.replaceAll(RegExp(r'\s+', unicode: true), '');
}
