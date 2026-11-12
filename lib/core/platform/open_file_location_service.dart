import 'dart:io';

typedef PlatformProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

final class OpenFileLocationService {
  factory OpenFileLocationService({
    PlatformProcessRunner runner = Process.run,
    bool? isWindows,
    bool? isLinux,
    bool? isMacOS,
  }) {
    return OpenFileLocationService._(runner, isWindows, isLinux, isMacOS);
  }

  const OpenFileLocationService._(
    this._runner,
    this._isWindowsOverride,
    this._isLinuxOverride,
    this._isMacOSOverride,
  );

  final PlatformProcessRunner _runner;
  final bool? _isWindowsOverride;
  final bool? _isLinuxOverride;
  final bool? _isMacOSOverride;

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;
  bool get _isLinux => _isLinuxOverride ?? Platform.isLinux;
  bool get _isMacOS => _isMacOSOverride ?? Platform.isMacOS;
  bool get isSupported => _isWindows || _isLinux || _isMacOS;

  Future<void> revealFile(String filePath) async {
    _ensureSupported();
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('文件不存在', filePath);
    }
    if (_isWindows) {
      await _run('explorer.exe', ['/select,${file.path}']);
    } else if (_isMacOS) {
      await _run('open', ['-R', file.absolute.path]);
    } else {
      await _run('xdg-open', [file.absolute.parent.path]);
    }
  }

  Future<void> openDirectory(String directoryPath) async {
    _ensureSupported();
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      throw FileSystemException('目录不存在', directoryPath);
    }
    await _run(
      switch ((_isWindows, _isMacOS)) {
        (true, _) => 'explorer.exe',
        (_, true) => 'open',
        _ => 'xdg-open',
      },
      [directory.absolute.path],
    );
  }

  void _ensureSupported() {
    if (!isSupported) {
      throw UnsupportedError('当前平台不支持打开文件所在位置');
    }
  }

  Future<void> _run(String executable, List<String> arguments) async {
    final result = await _runner(executable, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        result.stderr.toString(),
        result.exitCode,
      );
    }
  }
}
