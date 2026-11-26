import 'reading_translation.dart';

List<String> splitTranslationText(String text, {int maxRunes = 900}) {
  if (maxRunes < 2) throw ArgumentError.value(maxRunes, 'maxRunes');
  final runes = text.runes.toList();
  final chunks = <String>[];
  const boundaries = {32, 10, 0x3002, 0xff01, 0xff1f, 46, 33, 63, 59, 0xff1b};
  var start = 0;
  while (start < runes.length) {
    var end = (start + maxRunes).clamp(0, runes.length);
    if (end < runes.length) {
      for (
        var boundary = end - 1;
        boundary > start + maxRunes ~/ 2;
        boundary--
      ) {
        if (boundaries.contains(runes[boundary])) {
          end = boundary + 1;
          break;
        }
      }
    }
    chunks.add(String.fromCharCodes(runes.sublist(start, end)));
    start = end;
  }
  return chunks;
}

List<({String id, String text, bool protected})> translationWorkItems(
  ReadingTranslationUnit unit,
) {
  final pieces = <({String text, bool protected})>[
    for (final part in unit.parts)
      if (part.protected ||
          part.text.trim().isEmpty ||
          !RegExp(r'[A-Za-z\u00c0-\uffff]').hasMatch(part.text))
        (text: part.text, protected: true)
      else
        for (final chunk in splitTranslationText(part.text))
          (text: chunk, protected: chunk.trim().isEmpty),
  ];
  return [
    for (var index = 0; index < pieces.length; index++)
      (
        id: pieces.length == 1 ? unit.id : '${unit.id}/$index',
        text: pieces[index].text,
        protected: pieces[index].protected,
      ),
  ];
}
