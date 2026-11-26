import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/app/theme/app_theme.dart';
import 'package:pagesage/features/settings/presentation/model_picker_button.dart';

void main() {
  testWidgets(
    'model picker filters a fetched list and returns selected model',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ModelPickerButton(
              models: const ['qwen3-plus', 'deepseek-chat', 'qwen3-flash'],
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择模型'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'FLASH');
      await tester.pumpAndSettle();
      expect(find.text('deepseek-chat'), findsNothing);
      await tester.tap(find.text('qwen3-flash'));
      await tester.pumpAndSettle();
      expect(selected, 'qwen3-flash');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('empty filter and cancel preserve manual selection', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ModelPickerButton(
            models: const ['model-one'],
            onSelected: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择模型'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'absent');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的模型'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });
}
