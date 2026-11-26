import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/app/theme/app_theme.dart';
import 'package:pagesage/app/widgets/app_select_field.dart';

import '../../support/reader_workbench_capture.dart';

void main() {
  setUpAll(() async {
    if (captureWorkbench) await loadWorkbenchCaptureFonts();
  });

  Future<void> pumpField(
    WidgetTester tester, {
    double width = 1440,
    double scale = 1,
    bool dark = false,
    bool enabled = true,
    bool loading = false,
    ValueChanged<String>? onChanged,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const TextField(decoration: InputDecoration(labelText: '配置名称')),
                const SizedBox(height: 20),
                AppSelectField<String>(
                  key: const ValueKey('select-protocol'),
                  label: '接口协议',
                  value: 'openai',
                  options: const [
                    AppSelectOption(value: 'openai', label: 'OpenAI 兼容'),
                    AppSelectOption(value: 'libre', label: 'LibreTranslate'),
                  ],
                  onChanged: enabled ? (onChanged ?? (_) {}) : null,
                  loading: loading,
                ),
                const SizedBox(height: 20),
                const TextField(
                  decoration: InputDecoration(labelText: 'Base URL'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (loading) {
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'menu is compact, below anchor, and selected item has check mark',
    (tester) async {
      await pumpField(tester);
      final anchor = find.byKey(const ValueKey('select-protocol'));
      final anchorRect = tester.getRect(anchor);
      await tester.tap(anchor);
      await tester.pumpAndSettle();
      final option = find.byType(MenuItemButton).first;
      final optionRect = tester.getRect(option);
      expect(optionRect.width, lessThanOrEqualTo(400));
      expect(optionRect.width, lessThan(anchorRect.width / 2));
      expect(optionRect.top, greaterThanOrEqualTo(anchorRect.bottom));
      expect(optionRect.left, greaterThanOrEqualTo(anchorRect.left));
      expect(
        find.descendant(of: option, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clicking selection and dismissing menu preserve expected values',
    (tester) async {
      final selections = <String>[];
      await pumpField(tester, onChanged: selections.add);
      await tester.tap(find.byKey(const ValueKey('select-protocol')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'LibreTranslate'));
      await tester.pumpAndSettle();
      expect(selections, ['libre']);
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.tap(find.byKey(const ValueKey('select-protocol')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(800, 800));
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(selections, ['libre']);
    },
  );

  testWidgets('keyboard can open, choose next option and dismiss with escape', (
    tester,
  ) async {
    final selections = <String>[];
    await pumpField(tester, onChanged: selections.add);
    await tester.tap(find.byKey(const ValueKey('select-protocol')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selections, ['libre']);
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('disabled select cannot open menu', (tester) async {
    await pumpField(tester, enabled: false);
    await tester.tap(find.byKey(const ValueKey('select-protocol')));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact selector shares keyboard and disabled-item behavior on a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final selections = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: AppSelectField<String>(
                compact: true,
                label: '上下文范围',
                value: 'selected',
                options: const [
                  AppSelectOption(value: 'selected', label: '当前选区'),
                  AppSelectOption(
                    value: 'disabled',
                    label: '当前章节不可用',
                    enabled: false,
                  ),
                  AppSelectOption(value: 'library', label: '书库检索'),
                ],
                onChanged: selections.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('上下文范围'));
      await tester.pumpAndSettle();
      final disabled = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, '当前章节不可用'),
      );
      expect(disabled.onPressed, isNull);
      expect(
        tester.getRect(find.byType(MenuItemButton).first).right,
        lessThanOrEqualTo(360),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selections, ['library']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loading select reports progress and cannot open menu', (
    tester,
  ) async {
    await pumpField(tester, loading: true);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('select-protocol')));
    await tester.pump();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long option list scrolls within capped menu height', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: AppSelectField<String>(
              label: '语言',
              value: '0',
              options: List.generate(
                30,
                (index) => AppSelectOption(value: '$index', label: '选项 $index'),
              ),
              onChanged: (value) => selected = value,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(AppSelectField<String>));
    await tester.pumpAndSettle();
    final target = find.widgetWithText(MenuItemButton, '选项 29');
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(selected, '29');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'nullable default stays readable and is not selected when cancelled',
    (tester) async {
      String? selected = 'unchanged';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AppSelectField<String?>(
              label: '当前配置',
              value: null,
              options: const [
                AppSelectOption(value: null, label: '首次保存将创建默认配置'),
                AppSelectOption(value: 'saved', label: '已保存配置'),
              ],
              onChanged: (value) => selected = value,
            ),
          ),
        ),
      );
      expect(find.text('首次保存将创建默认配置'), findsOneWidget);
      await tester.tap(find.byType(AppSelectField<String?>));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(selected, 'unchanged');
    },
  );

  testWidgets('narrow dark select accommodates large text', (tester) async {
    await pumpField(tester, width: 390, scale: 1.5, dark: true);
    await tester.tap(find.byKey(const ValueKey('select-protocol')));
    await tester.pumpAndSettle();
    for (final option in find.byType(MenuItemButton).evaluate()) {
      final rect = tester.getRect(find.byWidget(option.widget));
      expect(rect.right, lessThanOrEqualTo(390));
      expect(rect.left, greaterThanOrEqualTo(0));
    }
    expect(tester.takeException(), isNull);
  });
}
