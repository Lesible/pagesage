import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/core/database/database_providers.dart';
import 'package:pagesage/core/files/app_paths.dart';
import 'package:pagesage/core/files/file_providers.dart';
import 'package:pagesage/core/platform/file_picker_service.dart';
import 'package:pagesage/core/platform/open_file_location_service.dart';
import 'package:pagesage/core/platform/platform_providers.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/core/tasks/task_models.dart';
import 'package:pagesage/features/settings/presentation/settings_page.dart';
import 'package:pagesage/features/settings/application/ai_settings_providers.dart';
import 'package:pagesage/features/export/application/export_providers.dart';

void main() {
  for (final cancel in [false, true]) {
    testWidgets('macOS image ZIP export handles cancellation: $cancel', (
      tester,
    ) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pagesage-macos-images-'),
      ))!;
      final database = AppDatabase.forTesting(
        DatabaseConnection(
          NativeDatabase.memory(),
          closeStreamsSynchronously: true,
        ),
      );
      final gate = Completer<String?>();
      final picker = _Picker(gate);
      final target = File('${root.path}/picked/images.zip');
      final opened = <List<String>>[];
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          appPathsProvider.overrideWithValue(
            AppPaths(overrideRoot: Directory('${root.path}/app')),
          ),
          secureStoreProvider.overrideWithValue(SecureStore.memory()),
          filePickerServiceProvider.overrideWithValue(
            FilePickerService(adapter: picker, isAndroid: false, isMacOS: true),
          ),
          openFileLocationServiceProvider.overrideWithValue(
            OpenFileLocationService(
              isWindows: false,
              isLinux: false,
              isMacOS: true,
              runner: (executable, arguments) async {
                expect(executable, 'open');
                opened.add(arguments);
                return ProcessResult(1, 0, '', '');
              },
            ),
          ),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: SettingsPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('隐私与数据').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('导出图片批注'));
        await tester.tap(find.text('导出图片批注'));
        await tester.pump();
        expect(picker.requests.single.allowedExtensions, ['zip']);
        gate.complete(cancel ? null : target.path);
        List<PageSageTask> tasks = [];
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump();
          tasks = (await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return container.read(taskRepositoryProvider).getTasks();
          }))!;
          if (cancel ||
              tasks.any(
                (task) =>
                    task.status == PageSageTaskStatus.done ||
                    task.status == PageSageTaskStatus.failed,
              )) {
            break;
          }
        }
        await tester.pumpAndSettle();
        if (cancel) {
          expect(tasks, isEmpty);
          expect(await tester.runAsync(target.exists), isFalse);
        } else {
          expect(tasks.single.status, PageSageTaskStatus.done);
          expect(tasks.single.targetPath, target.path);
          final bytes = (await tester.runAsync(target.readAsBytes))!;
          expect(
            ZipDecoder().decodeBytes(bytes).findFile('pagesage-images.md'),
            isNotNull,
          );
          expect(
            await tester.runAsync(
              () async => (await target.parent.list().toList())
                  .map((entry) => entry.path)
                  .toList(),
            ),
            [target.path],
          );
          await tester.tap(find.text('打开位置'));
          for (var attempt = 0; attempt < 50 && opened.isEmpty; attempt++) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          expect(opened.single, ['-R', target.path]);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.runAsync(database.close);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }

  for (final scenario in [
    (platform: 'Android', width: 430.0, images: false),
    (platform: 'iPad', width: 820.0, images: false),
    (platform: 'iPad split', width: 380.0, images: false),
    (platform: 'iPad', width: 820.0, images: true),
  ]) {
    for (final outcome in ['success', 'cancel', 'failure']) {
      testWidgets(
        '${scenario.platform} ${scenario.images ? 'images' : 'notes'} export $outcome finishes with the correct task state',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(scenario.width, 1000);
          addTearDown(tester.view.reset);
          final directory = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('pagesage-mobile-export-'),
          ))!;
          final database = AppDatabase.forTesting(
            DatabaseConnection(
              NativeDatabase.memory(),
              closeStreamsSynchronously: true,
            ),
          );
          const channel = MethodChannel('test/mobile/export');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          var saveCalls = 0;
          messenger.setMockMethodCallHandler(channel, (call) async {
            saveCalls++;
            expect(call.method, 'saveExport');
            final file = File(call.arguments['sourcePath'] as String);
            if (scenario.images) {
              expect(file.path, endsWith('.zip'));
              expect(
                ZipDecoder()
                    .decodeBytes(await file.readAsBytes())
                    .findFile('pagesage-images.md'),
                isNotNull,
              );
            } else {
              expect(await file.readAsString(), contains('# PageSage 笔记导出'));
            }
            if (outcome == 'failure') {
              throw PlatformException(code: 'export_write_failed');
            }
            return outcome == 'cancel'
                ? null
                : scenario.platform == 'Android'
                ? 'content://provider/saved.md'
                : 'file:///Documents/saved';
          });
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(database),
              appPathsProvider.overrideWithValue(
                AppPaths(overrideRoot: directory),
              ),
              secureStoreProvider.overrideWithValue(SecureStore.memory()),
              filePickerServiceProvider.overrideWithValue(
                FilePickerService(
                  isAndroid: scenario.platform == 'Android',
                  isMacOS: false,
                  isIOS: scenario.platform != 'Android',
                  filesChannel: channel,
                ),
              ),
              openFileLocationServiceProvider.overrideWithValue(
                OpenFileLocationService(
                  isWindows: false,
                  isLinux: false,
                  isMacOS: false,
                ),
              ),
            ],
          );
          try {
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: const MaterialApp(home: SettingsPage()),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('隐私与数据').first);
            await tester.pumpAndSettle();
            final exportLabel = scenario.images ? '导出图片批注' : '导出全部笔记';
            await tester.ensureVisible(find.text(exportLabel));
            await tester.tap(find.text(exportLabel));
            List<PageSageTask> tasks = [];
            for (var attempt = 0; attempt < 80; attempt++) {
              await tester.pump();
              tasks = (await tester.runAsync(() async {
                await Future<void>.delayed(const Duration(milliseconds: 20));
                return container.read(taskRepositoryProvider).getTasks();
              }))!;
              if (tasks.isNotEmpty &&
                  tasks.single.status != PageSageTaskStatus.running) {
                break;
              }
            }
            await tester.pumpAndSettle();
            expect(saveCalls, 1);
            expect(tasks.single.status, switch (outcome) {
              'success' => PageSageTaskStatus.done,
              'cancel' => PageSageTaskStatus.cancelled,
              _ => PageSageTaskStatus.failed,
            });
            expect(find.text('打开位置'), findsNothing);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            messenger.setMockMethodCallHandler(channel, null);
            container.dispose();
            await tester.runAsync(database.close);
            await tester.runAsync(() => directory.delete(recursive: true));
          }
        },
      );
    }
  }

  testWidgets(
    'restoring through settings succeeds after closing the old database',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pagesage-settings-restore-'),
      ))!;
      final paths = AppPaths(overrideRoot: root);
      final file = (await tester.runAsync(paths.databaseFile))!;
      await tester.runAsync(() => file.parent.create(recursive: true));
      final databases = <AppDatabase>[];
      late File backup;
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) {
            final database = AppDatabase.forTesting(
              DatabaseConnection(
                NativeDatabase(file),
                closeStreamsSynchronously: true,
              ),
            );
            databases.add(database);
            return database;
          }),
          appPathsProvider.overrideWithValue(paths),
          secureStoreProvider.overrideWithValue(SecureStore.memory()),
          filePickerServiceProvider.overrideWithValue(
            FilePickerService(adapter: _RestorePicker(() => backup.path)),
          ),
        ],
      );
      try {
        await tester.runAsync(() async {
          final database = container.read(appDatabaseProvider);
          await database
              .into(database.notes)
              .insert(
                NotesCompanion.insert(
                  id: 'note',
                  content: '备份中的笔记',
                  noteType: 'text',
                  createdAt: 1,
                  updatedAt: 1,
                ),
              );
          backup = await container
              .read(exportServiceProvider)
              .backupDatabaseZip(targetPath: '${root.path}/backup.zip');
          await database.customStatement(
            "UPDATE notes SET content = '后来修改的笔记'",
          );
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: SettingsPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('隐私与数据').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('恢复数据库备份'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('恢复数据库备份'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('恢复'));
        for (
          var attempt = 0;
          attempt < 200 && find.text('恢复完成').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
        }
        await tester.pumpAndSettle();
        expect(find.text('恢复完成'), findsOneWidget);
        expect(find.text('恢复失败：备份文件无效或无法写入'), findsNothing);
        final content = await tester.runAsync(() async {
          final database = container.read(appDatabaseProvider);
          return (await database.select(database.notes).getSingle()).content;
        });
        expect(content, '备份中的笔记');
        // Invalidating the database also restarts the settings stream. Let its
        // credential guard finish real file I/O before closing the temporary
        // database: Windows cannot delete an open credentials.lock file.
        for (
          var attempt = 0;
          attempt < 200 && container.read(aiSettingsProvider).isLoading;
          attempt++
        ) {
          await tester.pump();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
        }
        expect(container.read(aiSettingsProvider).hasValue, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.runAsync(() async {
          for (final database in databases) {
            await database.close();
          }
          await root.delete(recursive: true);
        });
      }
    },
  );

  for (final outcome in ['success', 'cancel', 'pickerError', 'writeError']) {
    testWidgets(
      'settings export handles $outcome without losing existing data',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('pagesage-settings-export-'),
        ))!;
        final database = AppDatabase.forTesting(
          DatabaseConnection(
            NativeDatabase.memory(),
            closeStreamsSynchronously: true,
          ),
        );
        final destination = File('${directory.path}/用户笔记.md');
        await tester.runAsync(() => destination.writeAsString('原导出'));
        final gate = Completer<String?>();
        final picker = _Picker(gate);
        final opened = <List<String>>[];
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            appPathsProvider.overrideWithValue(
              AppPaths(overrideRoot: directory),
            ),
            secureStoreProvider.overrideWithValue(SecureStore.memory()),
            filePickerServiceProvider.overrideWithValue(
              FilePickerService(adapter: picker),
            ),
            openFileLocationServiceProvider.overrideWithValue(
              OpenFileLocationService(
                isWindows: false,
                isLinux: true,
                isMacOS: false,
                runner: (executable, arguments) async {
                  expect(executable, 'xdg-open');
                  opened.add(arguments);
                  return ProcessResult(1, 0, '', '');
                },
              ),
            ),
          ],
        );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(home: SettingsPage()),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('隐私与数据').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('导出全部笔记'));
          await tester.pump();
          await tester.tap(find.text('导出全部笔记'));
          expect(picker.calls, 1);
          if (outcome == 'pickerError') {
            gate.completeError(const FileSystemException('picker unavailable'));
          } else if (outcome == 'cancel') {
            gate.complete(null);
          } else if (outcome == 'writeError') {
            final blocked = Directory('${directory.path}/blocked.md');
            await tester.runAsync(blocked.create);
            gate.complete(blocked.path);
          } else {
            gate.complete(destination.path);
          }
          List<PageSageTask> tasks = [];
          for (var attempt = 0; attempt < 50; attempt++) {
            await tester.pump();
            tasks = (await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 20));
              return container.read(taskRepositoryProvider).getTasks();
            }))!;
            if (outcome == 'cancel' ||
                outcome == 'pickerError' ||
                tasks.any(
                  (task) =>
                      task.status == PageSageTaskStatus.done ||
                      task.status == PageSageTaskStatus.failed,
                )) {
              break;
            }
          }
          await tester.pumpAndSettle();
          if (outcome == 'success') {
            expect(
              await tester.runAsync(destination.readAsString),
              contains('# PageSage 笔记导出'),
            );
            expect(tasks.single.status, PageSageTaskStatus.done);
            await tester.tap(find.text('打开位置'));
            for (var attempt = 0; attempt < 20 && opened.isEmpty; attempt++) {
              await tester.pump();
              await tester.runAsync(() async {
                await Future<void>.delayed(const Duration(milliseconds: 20));
              });
            }
            expect(opened.single, [directory.path]);
          } else {
            expect(await tester.runAsync(destination.readAsString), '原导出');
            if (outcome == 'writeError') {
              expect(tasks.single.status, PageSageTaskStatus.failed);
              expect(find.text('导出失败：请检查保存位置、写入权限和剩余空间'), findsOneWidget);
            } else {
              expect(tasks, isEmpty);
            }
            if (outcome == 'pickerError') {
              expect(find.text('无法选择文件，请重试或检查保存位置权限'), findsOneWidget);
            }
          }
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await tester.runAsync(database.close);
          await tester.runAsync(() => directory.delete(recursive: true));
        }
      },
    );
  }
}

class _Picker implements FilePickerAdapter {
  _Picker(this.gate);
  final Completer<String?> gate;
  int calls = 0;
  final requests = <FileSaveRequest>[];

  @override
  Future<String?> saveFile(FileSaveRequest request) {
    calls++;
    requests.add(request);
    return gate.future;
  }

  @override
  Future<List<PickedPlatformFile>> pickFiles(FilePickerRequest request) async =>
      [];

  @override
  Future<String?> pickDirectory({required String dialogTitle}) async => null;
}

class _RestorePicker implements FilePickerAdapter {
  _RestorePicker(this.path);
  final String Function() path;

  @override
  Future<List<PickedPlatformFile>> pickFiles(FilePickerRequest request) async =>
      [PickedPlatformFile(path: path(), name: 'backup.zip')];

  @override
  Future<String?> saveFile(FileSaveRequest request) async => null;

  @override
  Future<String?> pickDirectory({required String dialogTitle}) async => null;
}
