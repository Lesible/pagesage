import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/app/theme/app_theme.dart';
import 'package:pagesage/app/widgets/app_chrome.dart';
import 'package:pagesage/app/widgets/app_select_field.dart';
import 'package:pagesage/core/database/database_providers.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/domain/books/settings_repository.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/features/settings/application/ai_settings_providers.dart';
import 'package:pagesage/features/settings/application/settings_providers.dart';
import 'package:pagesage/features/settings/presentation/settings_page.dart';
import 'package:pagesage/features/translation/application/translation_providers.dart';
import 'package:pagesage/features/translation/presentation/translation_settings_panel.dart';

import '../../support/reader_workbench_capture.dart';

void main() {
  _SettingsCaptureBinding();
  setUpAll(() async {
    if (captureWorkbench) {
      await loadWorkbenchCaptureFonts();
    }
  });

  Future<_Settings> pump(
    WidgetTester tester, {
    double width = 1280,
    bool dark = false,
    bool page = false,
    bool readerEntry = false,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final settings = _Settings();
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await settings.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith(
            (ref) => throw StateError('No user database'),
          ),
          settingsRepositoryProvider.overrideWithValue(_ReaderSettings()),
          aiSettingsRepositoryProvider.overrideWithValue(_AiSettings()),
          translationSettingsRepositoryProvider.overrideWithValue(settings),
          translationGatewayProvider.overrideWithValue(_Gateway()),
          aiProfileRepositoryProvider.overrideWithValue(_AiProfiles()),
          secureStoreProvider.overrideWithValue(SecureStore.memory()),
          readerSettingsProvider.overrideWith(
            (ref) => Stream.value(const ReaderSettings()),
          ),
          aiSettingsProvider.overrideWith(
            (ref) => Stream.value(const AiSettings()),
          ),
          aiProfilesProvider.overrideWith(
            (ref) => Stream.value(const [
              AiProfile(id: 'ai-one', name: '本地 AI', model: 'test-model'),
            ]),
          ),
        ],
        child: MaterialApp(
          theme: captureWorkbench
              ? theme.copyWith(
                  chipTheme: theme.chipTheme.copyWith(
                    labelStyle: theme.chipTheme.labelStyle?.copyWith(
                      fontFamily: 'Segoe UI',
                    ),
                    secondaryLabelStyle: theme.chipTheme.secondaryLabelStyle
                        ?.copyWith(fontFamily: 'Segoe UI'),
                  ),
                )
              : theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: workbenchCaptureKey, child: child!),
          ),
          home: readerEntry
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsPage(
                            initialTranslation: true,
                            returnLabel: '返回阅读',
                          ),
                        ),
                      ),
                      child: const Text('打开翻译设置'),
                    ),
                  ),
                )
              : page
              ? const SettingsPage()
              : const Scaffold(
                  body: SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: TranslationSettingsPanel(),
                  ),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (readerEntry) {
      await tester.tap(find.text('打开翻译设置'));
      await tester.pumpAndSettle();
    }
    return settings;
  }

  for (final variant in [
    (width: 1280.0, scale: 1.0, dark: false),
    (width: 380.0, scale: 1.0, dark: false),
    (width: 380.0, scale: 2.0, dark: true),
  ]) {
    testWidgets('reader settings return stays accessible $variant', (
      tester,
    ) async {
      await pump(
        tester,
        width: variant.width,
        dark: variant.dark,
        scale: variant.scale,
        readerEntry: true,
      );
      expect(find.byType(TranslationSettingsPanel), findsOneWidget);
      final back = find.descendant(
        of: find.byType(AppPageHeader),
        matching: find.widgetWithText(TextButton, '返回阅读'),
      );
      expect(back.hitTestable(), findsOneWidget);
      expect(tester.getSize(back).height, greaterThanOrEqualTo(48));
      final semantics = tester.ensureSemantics();
      try {
        expect(find.bySemanticsLabel('返回阅读'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
      final colors = Theme.of(tester.element(back)).colorScheme;
      final foreground = colors.primary.computeLuminance();
      final background = colors.surface.computeLuminance();
      final lighter = foreground > background ? foreground : background;
      final darker = foreground < background ? foreground : background;
      expect((lighter + .05) / (darker + .05), greaterThanOrEqualTo(4.5));
      if (variant.width >= 900) {
        await tester.tap(find.text('阅读').first);
        await tester.pumpAndSettle();
        expect(back.hitTestable(), findsOneWidget);
        tester.view.physicalSize = const Size(380, 1000);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AppPageHeader),
            matching: find.text('阅读'),
          ),
          findsOneWidget,
        );
        expect(back.hitTestable(), findsOneWidget);
        tester.view.physicalSize = Size(variant.width, 1000);
        await tester.pumpAndSettle();
      } else {
        expect(find.text('翻译设置'), findsOneWidget);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -650));
        await tester.pumpAndSettle();
        expect(back.hitTestable(), findsOneWidget);
      }
      await captureWorkbenchWidget(
        tester,
        'settings-reader-return-${variant.width.toInt()}-${variant.scale}',
      );
      expect(tester.takeException(), isNull);
      if (variant.width >= 900) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<TextButton>(),
          same(tester.widget<TextButton>(back)),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(back);
      }
      await tester.pumpAndSettle();
      expect(find.text('打开翻译设置'), findsOneWidget);
      expect(find.byType(SettingsPage), findsNothing);
    });
  }

  testWidgets('main settings root has no misleading return-to-reader action', (
    tester,
  ) async {
    await pump(tester, page: true);
    expect(find.text('返回阅读'), findsNothing);
    expect(find.widgetWithText(TextButton, '返回'), findsNothing);
  });

  Future<void> chooseProvider(WidgetTester tester, String label) async {
    final dropdown = find.byWidgetPredicate(
      (widget) => widget is AppSelectField<TranslationProvider>,
    );
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop has separate AI and translation menus and correct content',
    (tester) async {
      await pump(tester, page: true);
      expect(find.text('翻译'), findsOneWidget);
      expect(find.byType(TranslationSettingsPanel), findsNothing);
      await tester.tap(find.text('翻译'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(TranslationSettingsPanel),
          matching: find.text('供应商'),
        ),
        findsOneWidget,
      );
      expect(find.text('保存 AI 设置'), findsNothing);
      await captureWorkbenchWidget(
        tester,
        'translation-settings-desktop-light',
      );
      await tester.tap(find.text('AI').first);
      await tester.pumpAndSettle();
      expect(find.byType(TranslationSettingsPanel), findsNothing);
      expect(find.text('拉取模型'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'provider fields change and credentials remain editable after switching',
    (tester) async {
      await pump(tester);
      for (final label in ['百度翻译', '有道智云', 'DeepL', '腾讯 TokenHub', 'Qwen-MT']) {
        await chooseProvider(tester, label);
        if (label == '百度翻译' || label == '有道智云') {
          expect(
            find.byKey(const ValueKey('translation-app-id')),
            findsOneWidget,
          );
        } else {
          expect(
            find.byKey(const ValueKey('translation-app-id')),
            findsNothing,
          );
        }
        final field = find.byKey(const ValueKey('translation-secret'));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'test-key');
        expect(tester.widget<TextFormField>(field).enabled, isTrue);
      }
      await chooseProvider(tester, '使用 AI 配置');
      expect(find.byKey(const ValueKey('translation-secret')), findsNothing);
      expect(find.text('AI 配置'), findsOneWidget);
      final aiSelector = find.byWidgetPredicate(
        (widget) => widget is AppSelectField<String> && widget.label == 'AI 配置',
      );
      await tester.ensureVisible(aiSelector);
      await tester.tap(aiSelector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地 AI · test-model').last);
      await tester.pumpAndSettle();
      expect(find.text('本地 AI · test-model'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('request interval defaults to one second', (tester) async {
    final settings = await pump(tester);
    final field = find.byKey(const ValueKey('translation-request-interval'));
    expect(tester.widget<TextFormField>(field).controller!.text, '1');
    await tester.ensureVisible(find.text('保存翻译配置'));
    await tester.tap(find.text('保存翻译配置'));
    await tester.pumpAndSettle();
    expect(settings.profiles.single.requestIntervalMs, 1000);
  });

  for (final seconds in ['0', '1.5', '60']) {
    testWidgets('request interval $seconds saves and reloads', (tester) async {
      final settings = await pump(tester);
      final field = find.byKey(const ValueKey('translation-request-interval'));
      await tester.ensureVisible(field);
      await tester.enterText(field, seconds);
      await tester.ensureVisible(find.text('保存翻译配置'));
      await tester.tap(find.text('保存翻译配置'));
      await tester.pumpAndSettle();
      expect(
        settings.profiles.single.requestIntervalMs,
        (double.parse(seconds) * 1000).round(),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, '3');
      await tester.ensureVisible(find.text('重新读取'));
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(field).controller!.text, seconds);
    });
  }

  testWidgets('invalid interval blocks save and keeps the draft editable', (
    tester,
  ) async {
    final settings = await pump(tester);
    final field = find.byKey(const ValueKey('translation-request-interval'));
    for (final input in ['', '-1', '60.001', 'NaN', 'Infinity', 'abc']) {
      await tester.ensureVisible(field);
      await tester.enterText(field, input);
      await tester.ensureVisible(find.text('保存翻译配置'));
      await tester.tap(find.text('保存翻译配置'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 0～60 秒之间的有效数字'), findsOneWidget);
      expect(settings.profiles, isEmpty);
      expect(tester.widget<TextFormField>(field).controller!.text, input);
    }
    await tester.ensureVisible(field);
    await tester.enterText(field, '2');
    await tester.ensureVisible(find.text('保存翻译配置'));
    await tester.tap(find.text('保存翻译配置'));
    await tester.pumpAndSettle();
    expect(settings.profiles.single.requestIntervalMs, 2000);
  });

  for (final variant in [
    (width: 1280.0, scale: 1.0, dark: false),
    (width: 380.0, scale: 2.0, dark: true),
  ]) {
    testWidgets('request interval field fits $variant', (tester) async {
      await pump(
        tester,
        width: variant.width,
        scale: variant.scale,
        dark: variant.dark,
      );
      final field = find.byKey(const ValueKey('translation-request-interval'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(field.hitTestable(), findsOneWidget);
      await captureWorkbenchWidget(
        tester,
        'translation-request-interval-${variant.width.round()}-${variant.scale}',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'save persists profile and trial calls selected provider without chat history',
    (tester) async {
      final settings = await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('translation-name')),
        '技术翻译',
      );
      await tester.enterText(
        find.byKey(const ValueKey('translation-secret')),
        'test-secret',
      );
      await tester.ensureVisible(find.text('保存翻译配置'));
      await tester.tap(find.text('保存翻译配置'));
      await tester.pumpAndSettle();
      expect(settings.profiles.single.name, '技术翻译');
      expect(settings.keys.single, 'test-secret');
      final trial = find.text('保存并试译');
      await tester.ensureVisible(trial);
      await tester.tap(trial);
      await tester.pumpAndSettle();
      expect(find.text('配置已保存，试译完成'), findsOneWidget);
      expect(find.text('试译结果'), findsOneWidget);
      expect(settings.keys.last, '');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed save keeps input and offers retry', (tester) async {
    final settings = await pump(tester);
    settings.fail = true;
    await tester.enterText(
      find.byKey(const ValueKey('translation-name')),
      '保留草稿',
    );
    await tester.ensureVisible(find.text('保存翻译配置'));
    await tester.tap(find.text('保存翻译配置'));
    await tester.pumpAndSettle();
    expect(find.text('测试保存失败'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('translation-name')))
          .controller
          ?.text,
      '保留草稿',
    );
    settings.fail = false;
    await tester.tap(find.text('保存翻译配置'));
    await tester.pumpAndSettle();
    expect(settings.profiles.single.name, '保留草稿');
  });

  testWidgets('narrow dark form supports custom protocol without overflow', (
    tester,
  ) async {
    await pump(tester, width: 390, dark: true);
    await chooseProvider(tester, '自定义供应商');
    expect(find.text('接口协议'), findsOneWidget);
    expect(find.text('拉取模型'), findsOneWidget);
    await captureWorkbenchWidget(tester, 'translation-settings-narrow-dark');
    expect(tester.takeException(), isNull);
  });
  for (final scenario in [
    (width: 1280.0, dark: false, scale: 1.0),
    (width: 1280.0, dark: true, scale: 1.0),
    (width: 390.0, dark: true, scale: 1.5),
  ]) {
    testWidgets('expanded translation menus fit $scenario', (tester) async {
      await pump(
        tester,
        width: scenario.width,
        dark: scenario.dark,
        scale: scenario.scale,
        page: true,
      );
      await tester.tap(find.text('翻译').first);
      await tester.pumpAndSettle();
      final provider = find.byType(AppSelectField<TranslationProvider>);
      await tester.ensureVisible(provider);
      await tester.tap(provider);
      await tester.pumpAndSettle();
      await captureWorkbenchWidget(
        tester,
        'translation-provider-menu-${scenario.width.round()}-${scenario.dark}-${scenario.scale}',
      );
      final custom = find.widgetWithText(MenuItemButton, '自定义供应商');
      await tester.ensureVisible(custom);
      await tester.tap(custom);
      await tester.pumpAndSettle();
      final protocol = find.byType(AppSelectField<TranslationProtocol>);
      await tester.ensureVisible(protocol);
      await tester.tap(protocol);
      await tester.pumpAndSettle();
      await captureWorkbenchWidget(
        tester,
        'translation-protocol-menu-${scenario.width.round()}-${scenario.dark}-${scenario.scale}',
      );
      await tester.tap(find.widgetWithText(MenuItemButton, 'LibreTranslate'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('translation-model')), findsNothing);
      expect(find.text('自托管服务无需鉴权时可留空。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

final class _SettingsCaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => !captureWorkbench;
}

final class _Settings implements TranslationSettingsRepository {
  final _events = StreamController<TranslationSettings>.broadcast();
  final profiles = <TranslationProfile>[];
  final keys = <String?>[];
  bool fail = false;
  String? defaultId;
  Future<void> dispose() => _events.close();
  TranslationSettings get settings =>
      TranslationSettings(profiles: profiles, defaultProfileId: defaultId);
  @override
  Stream<TranslationSettings> watchSettings() async* {
    yield settings;
    yield* _events.stream;
  }

  @override
  Future<TranslationSettings> getSettings() async => settings;
  @override
  Future<TranslationProfile> saveProfile(
    TranslationProfile profile, {
    String? secret,
    bool clearSecret = false,
  }) async {
    if (fail) throw const TranslationException('测试保存失败');
    keys.add(secret);
    final saved = profile.withStorage(
      revision: profile.revision + 1,
      credentialRef: 'translation.secret.test',
      hasCredential: true,
    );
    profiles.removeWhere((entry) => entry.id == profile.id);
    profiles.add(saved);
    defaultId ??= saved.id;
    _events.add(settings);
    return saved;
  }

  @override
  Future<void> deleteProfile(String id, {required int expectedRevision}) async {
    profiles.removeWhere((entry) => entry.id == id);
    _events.add(settings);
  }

  @override
  Future<void> setDefaultProfile(String id) async {
    defaultId = id;
    _events.add(settings);
  }

  @override
  Future<String?> readCredential(TranslationProfile profile) async =>
      'test-secret';
  @override
  Future<void> clearCredentials() async {}
}

final class _Gateway implements TranslationGateway {
  @override
  Future<TranslationResult> translate({
    required TranslationProfile profile,
    required String text,
    String? secret,
    AiProfile? aiProfile,
    AiCancelToken? cancelToken,
  }) async => const TranslationResult(text: '试译结果');
}

final class _AiProfiles implements AiProfileRepository {
  @override
  Future<AiProfile?> getProfile(String id) async => null;
  @override
  Future<List<AiProfile>> listProfiles() async => [];
  @override
  Stream<List<AiProfile>> watchProfiles() => Stream.value([]);
  @override
  Future<AiProfile> createProfile({
    required String name,
    String? sourceProfileId,
    bool copyCredential = false,
  }) => throw UnimplementedError();
  @override
  Future<AiProfile> updateProfile(
    AiProfile profile, {
    String? apiKey,
    required int expectedRevision,
  }) => throw UnimplementedError();
  @override
  Future<void> deleteProfile(String id, {String? replacementProfileId}) =>
      throw UnimplementedError();
  @override
  Future<void> setActiveProfile(String? id) => throw UnimplementedError();
}

final class _ReaderSettings implements SettingsRepository {
  @override
  Future<ReaderSettings> getReaderSettings() async => const ReaderSettings();
  @override
  Stream<ReaderSettings> watchReaderSettings() =>
      Stream.value(const ReaderSettings());
  @override
  Future<void> saveReaderSettings(ReaderSettings settings) async {}
}

final class _AiSettings implements AiSettingsRepository {
  @override
  Future<AiSettings> getSettings() async => const AiSettings();
  @override
  Stream<AiSettings> watchSettings() => Stream.value(const AiSettings());
  @override
  Future<void> saveSettings(AiSettings settings, {String? apiKey}) async {}
  @override
  Future<void> clearApiKey() async {}
}
