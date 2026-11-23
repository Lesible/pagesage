import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:pagesage/core/files/app_paths.dart';
import 'package:pagesage/core/platform/file_picker_service.dart';
import 'package:pagesage/core/platform/macos_folder_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in ['macOS', 'iOS', 'other']) {
    test('image export selects the appropriate format on $platform', () async {
      final usesArchive = platform != 'other';
      final adapter = _FakeFilePickerAdapter(const [], savePath: '/tmp/export');
      final picker = FilePickerService(
        adapter: adapter,
        isAndroid: false,
        isMacOS: platform == 'macOS',
        isIOS: platform == 'iOS',
      );
      await picker.pickImageAnnotationsExportPath();
      expect(picker.usesImageExportArchive, usesArchive);
      expect(picker.supportsExportPathSelection, platform != 'iOS');
      expect(
        adapter.saveRequests.single.fileName,
        usesArchive ? 'pagesage-images.zip' : 'pagesage-images.md',
      );
      expect(adapter.saveRequests.single.allowedExtensions, [
        usesArchive ? 'zip' : 'md',
      ]);
    });
  }

  for (final cancel in [false, true]) {
    test(
      'iOS export preserves source files on cancellation: $cancel',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'pagesage-ios-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final source = File('${directory.path}/images.zip');
        await source.writeAsBytes([1, 2, 3]);
        const channel = MethodChannel('test/ios/files');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveExport');
          expect(call.arguments, {
            'sourcePath': source.absolute.path,
            'name': 'images.zip',
            'mimeType': 'application/zip',
          });
          return cancel ? null : 'file:///Documents/images.zip';
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final picker = FilePickerService(
          isAndroid: false,
          isMacOS: false,
          isIOS: true,
          filesChannel: channel,
        );
        expect(picker.supportsExportPathSelection, isFalse);
        expect(
          await picker.saveExportedFile(source),
          cancel ? null : 'file:///Documents/images.zip',
        );
        expect(await source.readAsBytes(), [1, 2, 3]);
        expect(await directory.list().length, 1);
      },
    );

    test(
      'iOS folder selection remembers only selected grants: $cancel',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'pagesage-ios-',
        );
        addTearDown(() => directory.delete(recursive: true));
        const filesChannel = MethodChannel('test/ios/files');
        const bookmarksChannel = MethodChannel('pagesage/ios_bookmarks');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final created = <String>[];
        messenger.setMockMethodCallHandler(filesChannel, (call) async {
          expect(call.method, 'pickFolder');
          return cancel ? null : directory.path;
        });
        messenger.setMockMethodCallHandler(bookmarksChannel, (call) async {
          expect(call.method, 'create');
          created.add(call.arguments['path'] as String);
          return 'ios-grant';
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(filesChannel, null);
          messenger.setMockMethodCallHandler(bookmarksChannel, null);
        });
        final picker = FilePickerService(
          isAndroid: false,
          isMacOS: false,
          isIOS: true,
          filesChannel: filesChannel,
          folderAccess: MacOSFolderAccess(
            appPaths: AppPaths(overrideRoot: directory),
            isMacOS: false,
            isIOS: true,
          ),
        );
        expect(
          await picker.pickFolder(rememberFolderAccess: true),
          cancel ? null : directory.path,
        );
        expect(created, cancel ? isEmpty : [directory.path]);
        expect(
          await File('${directory.path}/ios-bookmarks.json').exists(),
          !cancel,
        );
        expect(
          await File('${directory.path}/macos-bookmarks.json').exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'Android exports stream a generated file and preserve content URIs',
    () async {
      const channel = MethodChannel('test/pagesage/files');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'content://documents/tree/export.md';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final picker = FilePickerService(isAndroid: true, filesChannel: channel);
      expect(picker.supportsExportPathSelection, isFalse);
      final path = File('/tmp/notes.md');
      expect(
        await picker.saveExportedFile(path),
        'content://documents/tree/export.md',
      );
      expect(calls.single.method, 'saveExport');
      expect(calls.single.arguments, {
        'sourcePath': path.absolute.path,
        'name': 'notes.md',
        'mimeType': 'text/markdown',
      });
    },
  );

  test('Android document picker cancellation stays cancellation', () async {
    const channel = MethodChannel('test/pagesage/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(
      await FilePickerService(
        isAndroid: true,
        filesChannel: channel,
      ).saveExportedFile(File('/tmp/backup.zip')),
      isNull,
    );
  });
  test(
    'selecting an export destination does not truncate an existing file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pagesage-picker-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/notes.md');
      await target.writeAsString('原导出');
      final picker = FilePickerService(
        adapter: FilePickerPluginAdapter(
          pickSaveLocation: (request) async => target.path,
        ),
      );
      expect(await picker.pickNotesMarkdownExportPath(), target.path);
      expect(await target.readAsString(), '原导出');
    },
  );

  test('cancelling destination selection creates no files', () async {
    final picker = FilePickerService(
      adapter: FilePickerPluginAdapter(pickSaveLocation: (_) async => null),
    );
    expect(await picker.pickNotesMarkdownExportPath(), isNull);
  });
  test('pickBookFile requests a single EPUB, PDF, or Markdown file', () async {
    final adapter = _FakeFilePickerAdapter([
      const PickedPlatformFile(path: r'C:\books\demo.epub', name: 'demo.epub'),
    ]);
    final service = FilePickerService(adapter: adapter);

    final file = await service.pickBookFile();

    expect(file?.path, r'C:\books\demo.epub');
    expect(file?.name, 'demo.epub');
    expect(adapter.requests.single.allowMultiple, isFalse);
    expect(adapter.requests.single.allowedExtensions, [
      'epub',
      'pdf',
      'md',
      'markdown',
    ]);
    expect(adapter.requests.single.dialogTitle, '导入 EPUB/PDF/Markdown');
  });

  test(
    'pickBookFiles requests multiple EPUB, PDF, or Markdown files',
    () async {
      final adapter = _FakeFilePickerAdapter([
        const PickedPlatformFile(path: r'C:\books\a.epub', name: 'a.epub'),
        const PickedPlatformFile(path: r'C:\books\b.pdf', name: 'b.pdf'),
      ]);
      final service = FilePickerService(adapter: adapter);

      final files = await service.pickBookFiles();

      expect(files.map((file) => file.name), ['a.epub', 'b.pdf']);
      expect(adapter.requests.single.allowMultiple, isTrue);
      expect(adapter.requests.single.allowedExtensions, [
        'epub',
        'pdf',
        'md',
        'markdown',
      ]);
      expect(adapter.requests.single.dialogTitle, '导入 EPUB/PDF/Markdown');
    },
  );

  test('pickBackupZipFile requests a single zip file', () async {
    final adapter = _FakeFilePickerAdapter([
      const PickedPlatformFile(
        path: r'C:\backups\pagesage.zip',
        name: 'pagesage.zip',
      ),
    ]);
    final service = FilePickerService(adapter: adapter);

    final file = await service.pickBackupZipFile();

    expect(file?.path, r'C:\backups\pagesage.zip');
    expect(adapter.requests.single.allowMultiple, isFalse);
    expect(adapter.requests.single.allowedExtensions, ['zip']);
    expect(adapter.requests.single.dialogTitle, '选择 PageSage 备份文件');
  });

  test('returns null or empty lists when the picker is cancelled', () async {
    final adapter = _FakeFilePickerAdapter(const []);
    final service = FilePickerService(adapter: adapter);

    expect(await service.pickBookFile(), isNull);
    expect(await service.pickBackupZipFile(), isNull);
    expect(await service.pickBookFiles(), isEmpty);
  });

  test('save export path requests markdown file', () async {
    final adapter = _FakeFilePickerAdapter(
      const [],
      savePath: r'C:\exports\notes.md',
    );
    final service = FilePickerService(adapter: adapter);

    final path = await service.pickNotesMarkdownExportPath();

    expect(path, r'C:\exports\notes.md');
    expect(adapter.saveRequests.single.dialogTitle, '导出全部笔记');
    expect(adapter.saveRequests.single.allowedExtensions, ['md']);
  });

  group('image save path', () {
    test('writes the PNG the renderer produced', () async {
      final adapter = _FakeFilePickerAdapter(
        const [],
        savePath: r'D:\pictures\page.png',
      );
      final service = FilePickerService(adapter: adapter);
      final bytes = [0x89, 0x50, 0x4E, 0x47];

      final path = await service.pickImageSavePath(
        baseName: '一本书 第 12 页',
        bytes: bytes,
      );

      expect(path, r'D:\pictures\page.png');
      final request = adapter.saveRequests.single;
      expect(request.fileName, '一本书 第 12 页.png');
      expect(request.allowedExtensions, ['png']);
      // The bytes go through the save call; file_picker 12 no longer writes
      // the file itself, so passing them here is the only way it lands.
      expect(request.bytes, bytes);
    });

    test('a title with path separators cannot escape the folder', () async {
      final adapter = _FakeFilePickerAdapter(const [], savePath: '/tmp/a.png');
      final service = FilePickerService(adapter: adapter);

      await service.pickImageSavePath(
        baseName: 'a/b\\c:d*e?f"g<h>i|j',
        bytes: const [1],
      );

      final name = adapter.saveRequests.single.fileName;
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('\\')));
      expect(name, isNot(contains(':')));
      expect(name.endsWith('.png'), isTrue);
    });

    test('an empty title still yields a usable file name', () async {
      final adapter = _FakeFilePickerAdapter(const [], savePath: '/tmp/a.png');
      final service = FilePickerService(adapter: adapter);

      await service.pickImageSavePath(baseName: '   ', bytes: const [1]);

      expect(adapter.saveRequests.single.fileName, 'pagesage-image.png');
    });
  });
}

final class _FakeFilePickerAdapter implements FilePickerAdapter {
  _FakeFilePickerAdapter(this.files, {this.savePath});

  final List<PickedPlatformFile> files;
  final String? savePath;
  final List<FilePickerRequest> requests = [];
  final List<FileSaveRequest> saveRequests = [];

  @override
  Future<List<PickedPlatformFile>> pickFiles(FilePickerRequest request) async {
    requests.add(request);
    return files;
  }

  @override
  Future<String?> saveFile(FileSaveRequest request) async {
    saveRequests.add(request);
    return savePath;
  }

  @override
  Future<String?> pickDirectory({required String dialogTitle}) async => null;
}
