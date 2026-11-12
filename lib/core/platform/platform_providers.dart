import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/file_providers.dart';
import 'file_picker_service.dart';
import 'macos_folder_access.dart';
import 'open_file_location_service.dart';
import 'window_drop_import_service.dart';

final macosFolderAccessProvider = Provider<MacOSFolderAccess>(
  (ref) => MacOSFolderAccess(appPaths: ref.watch(appPathsProvider)),
);

final filePickerServiceProvider = Provider<FilePickerService>(
  (ref) =>
      FilePickerService(folderAccess: ref.watch(macosFolderAccessProvider)),
);

final openFileLocationServiceProvider = Provider<OpenFileLocationService>(
  (ref) => OpenFileLocationService(),
);

final windowDropImportServiceProvider = Provider<WindowDropImportService>((
  ref,
) {
  final service = WindowDropImportService();
  ref.onDispose(service.dispose);
  return service;
});
