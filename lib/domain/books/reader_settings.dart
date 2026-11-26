import 'dart:convert';

import 'package:flutter/material.dart';

enum ReaderThemePreset {
  day('day', '素白', Color(0xFFFAFAF8), Color(0xFF292C30), Color(0xFF355F80)),
  paper('paper', '书纸', Color(0xFFF7F3EB), Color(0xFF332F29), Color(0xFF766044)),
  warm('warm', '暖砂', Color(0xFFF2ECE3), Color(0xFF3B332C), Color(0xFF80513C)),
  amber('amber', '燕麦', Color(0xFFEBE4D7), Color(0xFF393127), Color(0xFF79562E)),
  night('night', '夜间', Color(0xFF1D2229), Color(0xFFDDE2E8), Color(0xFF96BBCB)),
  green('green', '雾绿', Color(0xFFEDF1EC), Color(0xFF2D3731), Color(0xFF42695C)),
  sage('sage', '灰蓝', Color(0xFFEBF0F3), Color(0xFF2D3540), Color(0xFF426780)),
  ink(
    'ink',
    '墨水屏',
    Color(0xFFEEEFEA),
    Color(0xFF262923),
    Color(0xFF4C6154),
    epubInk: true,
  ),
  inkWarm(
    'ink-warm',
    '暖墨',
    Color(0xFFECE8DF),
    Color(0xFF302D28),
    Color(0xFF685B49),
    epubInk: true,
  ),
  contrast(
    'contrast',
    '高对比',
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFF0047B3),
  );

  const ReaderThemePreset(
    this.value,
    this.label,
    this.background,
    this.foreground,
    this.link, {
    this.epubInk = false,
  });

  final String value;
  final String label;
  final Color background;
  final Color foreground;
  final Color link;
  final bool epubInk;

  static ReaderThemePreset fromValue(String value) {
    return values.firstWhere(
      (preset) => preset.value == value,
      orElse: () => ReaderThemePreset.day,
    );
  }
}

enum ReaderMode {
  continuous('continuous', '连续滚动'),
  paged('paged', '分页');

  const ReaderMode(this.value, this.label);

  final String value;
  final String label;

  static ReaderMode fromValue(String value) {
    return values.firstWhere(
      (mode) => mode.value == value,
      orElse: () => ReaderMode.continuous,
    );
  }
}

enum ReaderContextTab { search, notebook, ai }

enum PdfZoomMode {
  custom('custom', '自定义'),
  actual('actual', '实际大小'),
  fitWidth('fit-width', '适合宽度'),
  fitPage('fit-page', '适合页面');

  const PdfZoomMode(this.value, this.label);

  final String value;
  final String label;

  static PdfZoomMode fromValue(String value) {
    return values.firstWhere(
      (mode) => mode.value == value,
      orElse: () => PdfZoomMode.custom,
    );
  }
}

final class ReaderSettings {
  /// Bounds for [pdfScale], shared with the renderer's zoom resolution.
  ///
  /// The WebView bridge used 0.5–3.0; the old reader toolbar clamped to
  /// 0.7–2.4, so a scale saved by the bridge could not be reproduced. Keeping
  /// one range keeps stored locators portable between renderers.
  static const double pdfScaleMin = 0.5;
  static const double pdfScaleMax = 3.0;

  const ReaderSettings({
    this.appThemeMode = ThemeMode.system,
    this.fontFamily = '',
    this.fontSize = 18,
    this.lineHeight = 1.7,
    this.paragraphSpacing = 12,
    this.pageMargin = 24,
    this.readerMode = ReaderMode.continuous,
    // Fit-width is the least surprising default on phones and small windows;
    // custom 1.2x used to overflow and look "squashed" under old CSS max-width.
    this.pdfScale = 1.0,
    this.pdfZoomMode = PdfZoomMode.fitWidth,
    this.themePreset = ReaderThemePreset.day,
    this.reduceMotion = false,
    this.desktopTocOpen = true,
    this.desktopContextOpen = false,
    this.desktopTocWidth = 300,
    this.desktopContextWidth = 420,
    this.desktopContextTab = ReaderContextTab.search,
  });

  final ThemeMode appThemeMode;
  final String fontFamily;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double pageMargin;
  final ReaderMode readerMode;
  final double pdfScale;
  final PdfZoomMode pdfZoomMode;
  final ReaderThemePreset themePreset;
  final bool reduceMotion;
  final bool desktopTocOpen;
  final bool desktopContextOpen;
  final double desktopTocWidth;
  final double desktopContextWidth;
  final ReaderContextTab desktopContextTab;

  ReaderSettings copyWith({
    ThemeMode? appThemeMode,
    String? fontFamily,
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? pageMargin,
    ReaderMode? readerMode,
    double? pdfScale,
    PdfZoomMode? pdfZoomMode,
    ReaderThemePreset? themePreset,
    bool? reduceMotion,
    bool? desktopTocOpen,
    bool? desktopContextOpen,
    double? desktopTocWidth,
    double? desktopContextWidth,
    ReaderContextTab? desktopContextTab,
  }) {
    return ReaderSettings(
      appThemeMode: appThemeMode ?? this.appThemeMode,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      pageMargin: pageMargin ?? this.pageMargin,
      readerMode: readerMode ?? this.readerMode,
      pdfScale: pdfScale ?? this.pdfScale,
      pdfZoomMode: pdfZoomMode ?? this.pdfZoomMode,
      themePreset: themePreset ?? this.themePreset,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      desktopTocOpen: desktopTocOpen ?? this.desktopTocOpen,
      desktopContextOpen: desktopContextOpen ?? this.desktopContextOpen,
      desktopTocWidth: desktopTocWidth ?? this.desktopTocWidth,
      desktopContextWidth: desktopContextWidth ?? this.desktopContextWidth,
      desktopContextTab: desktopContextTab ?? this.desktopContextTab,
    );
  }

  ReaderSettings resetReadingAppearance() {
    return copyWith(
      fontFamily: '',
      fontSize: 18,
      lineHeight: 1.7,
      paragraphSpacing: 12,
      pageMargin: 24,
      readerMode: ReaderMode.continuous,
      pdfScale: 1,
      pdfZoomMode: PdfZoomMode.fitWidth,
      themePreset: ReaderThemePreset.day,
    );
  }

  ReaderSettings mergeOverride(ReaderSettingsOverride override) {
    return copyWith(
      appThemeMode: override.appThemeMode,
      fontFamily: override.fontFamily,
      fontSize: override.fontSize,
      lineHeight: override.lineHeight,
      paragraphSpacing: override.paragraphSpacing,
      pageMargin: override.pageMargin,
      readerMode: override.readerMode,
      pdfScale: override.pdfScale,
      pdfZoomMode: override.pdfZoomMode,
      themePreset: override.themePreset,
      reduceMotion: override.reduceMotion,
    );
  }

  String toJsonText() {
    return jsonEncode({
      'themeMode': appThemeMode.name,
      'fontFamily': fontFamily,
      'fontSize': fontSize,
      'lineHeight': lineHeight,
      'paragraphSpacing': paragraphSpacing,
      'pageMargin': pageMargin,
      'readerMode': readerMode.value,
      'pdfScale': pdfScale,
      'pdfZoomMode': pdfZoomMode.value,
      'themePreset': themePreset.value,
      'reduceMotion': reduceMotion,
      'desktopTocOpen': desktopTocOpen,
      'desktopContextOpen': desktopContextOpen,
      'desktopTocWidth': desktopTocWidth,
      'desktopContextWidth': desktopContextWidth,
      'desktopContextTab': desktopContextTab.name,
    });
  }

  static ReaderSettings fromJsonText(String? value) {
    if (value == null || value.isEmpty) {
      return const ReaderSettings();
    }

    final json = jsonDecode(value) as Map<String, Object?>;
    return ReaderSettings(
      appThemeMode: _themeModeFromName(json['themeMode'] as String?),
      fontFamily: json['fontFamily'] as String? ?? '',
      fontSize: _asDouble(json['fontSize']) ?? 18,
      lineHeight: _asDouble(json['lineHeight']) ?? 1.7,
      paragraphSpacing: _asDouble(json['paragraphSpacing']) ?? 12,
      pageMargin: _asDouble(json['pageMargin']) ?? 24,
      readerMode: ReaderMode.fromValue(
        json['readerMode'] as String? ?? ReaderMode.continuous.value,
      ),
      pdfScale: _asDouble(json['pdfScale']) ?? 1.0,
      pdfZoomMode: PdfZoomMode.fromValue(
        json['pdfZoomMode'] as String? ?? PdfZoomMode.fitWidth.value,
      ),
      themePreset: ReaderThemePreset.fromValue(
        json['themePreset'] as String? ?? ReaderThemePreset.day.value,
      ),
      reduceMotion: json['reduceMotion'] == true,
      desktopTocOpen: json['desktopTocOpen'] != false,
      desktopContextOpen: json['desktopContextOpen'] == true,
      desktopTocWidth: _asDouble(json['desktopTocWidth']) ?? 300,
      desktopContextWidth: _asDouble(json['desktopContextWidth']) ?? 360,
      desktopContextTab: ReaderContextTab.values.firstWhere(
        (tab) => tab.name == json['desktopContextTab'],
        orElse: () => ReaderContextTab.search,
      ),
    );
  }

  static ThemeMode _themeModeFromName(String? value) {
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => ThemeMode.system,
    );
  }

  static double? _asDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }
}

final class ReaderSettingsOverride {
  const ReaderSettingsOverride({
    this.appThemeMode,
    this.fontFamily,
    this.fontSize,
    this.lineHeight,
    this.paragraphSpacing,
    this.pageMargin,
    this.readerMode,
    this.pdfScale,
    this.pdfZoomMode,
    this.themePreset,
    this.reduceMotion,
  });

  final ThemeMode? appThemeMode;
  final String? fontFamily;
  final double? fontSize;
  final double? lineHeight;
  final double? paragraphSpacing;
  final double? pageMargin;
  final ReaderMode? readerMode;
  final double? pdfScale;
  final PdfZoomMode? pdfZoomMode;
  final ReaderThemePreset? themePreset;
  final bool? reduceMotion;
}
