import 'web_book.dart';

final class WebChapterGroup {
  const WebChapterGroup(this.key, this.label, this.chapters);
  final String key;
  final String label;
  final List<WebChapter> chapters;
}

String webChapterSourceKey(WebChapter chapter) {
  final uri = Uri.tryParse(chapter.url);
  return uri == null || uri.host.isEmpty
      ? 'unknown'
      : uri.authority.toLowerCase();
}

List<WebChapterGroup> groupWebChapters(
  List<WebChapter> chapters, {
  String filter = '',
}) {
  final query = filter.trim().toLowerCase();
  final groups = <String, List<WebChapter>>{};
  for (final chapter in chapters) {
    final source = webChapterSourceKey(chapter);
    if (query.isNotEmpty &&
        !chapter.displayTitle.toLowerCase().contains(query) &&
        !chapter.url.toLowerCase().contains(query)) {
      continue;
    }
    groups.putIfAbsent(source, () => []).add(chapter);
  }
  return [
    for (final group in groups.entries)
      WebChapterGroup(
        group.key,
        group.key == 'unknown' ? '其他来源' : group.key,
        List.unmodifiable(group.value),
      ),
  ];
}
