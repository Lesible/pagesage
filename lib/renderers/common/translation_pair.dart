import 'package:flutter/material.dart';

import '../../domain/translation/reading_translation.dart';

final class TranslationPair extends StatelessWidget {
  const TranslationPair({
    required this.original,
    required this.translated,
    required this.mode,
    required this.style,
    super.key,
  });
  final Widget original;
  final String? translated;
  final TranslationDisplayMode mode;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final translation = SelectionContainer.disabled(
      child: SelectionArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            translated ?? '此段尚未翻译',
            style: translated == null
                ? style.copyWith(
                    fontSize: 13,
                    color: style.color?.withValues(alpha: .7),
                  )
                : style,
          ),
        ),
      ),
    );
    if (mode == TranslationDisplayMode.translated && translated != null) {
      return translation;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              original,
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 12),
                child: translation,
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: original),
            const SizedBox(width: 28),
            Expanded(child: translation),
          ],
        );
      },
    );
  }
}
