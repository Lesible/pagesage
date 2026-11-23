import Flutter
import UIKit
import UniformTypeIdentifiers

final class PagesageFileChannels: NSObject, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate {
  private let filesChannel: FlutterMethodChannel
  private let bookmarksChannel: FlutterMethodChannel
  private var activeURLs: [String: URL] = [:]
  private var pendingResult: FlutterResult?
  private var selectingFolder = false
  private var selectingFiles = false
  private weak var activePicker: UIDocumentPickerViewController?

  init(messenger: FlutterBinaryMessenger) {
    filesChannel = FlutterMethodChannel(name: "pagesage/files", binaryMessenger: messenger)
    bookmarksChannel = FlutterMethodChannel(
      name: "pagesage/ios_bookmarks", binaryMessenger: messenger
    )
    super.init()
    filesChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleFileCall(call, result: result)
    }
    bookmarksChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleBookmarkCall(call, result: result)
    }
  }

  private func handleFileCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["pickFolder", "pickFiles", "saveExport"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pendingResult == nil else {
      result(FlutterError(code: "picker_busy", message: "请先关闭当前文件面板", details: nil))
      return
    }
    pendingResult = result
    selectingFolder = call.method == "pickFolder"
    selectingFiles = call.method == "pickFiles"
    guard let presenter = presentingController() else {
      finish(FlutterError(code: "picker_unavailable", message: "无法打开文件面板", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    let args = call.arguments as? [String: Any] ?? [:]
    if selectingFolder {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    } else if selectingFiles {
      let extensions = args["allowedExtensions"] as? [String] ?? []
      let types = extensions.compactMap { UTType(filenameExtension: $0) }
      guard !types.isEmpty else {
        finish(FlutterError(code: "invalid_arguments", message: "未指定文件类型", details: nil))
        return
      }
      picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    } else {
      guard let path = args["sourcePath"] as? String,
            FileManager.default.fileExists(atPath: path) else {
        finish(FlutterError(code: "file_not_found", message: "找不到导出文件", details: nil))
        return
      }
      picker = UIDocumentPickerViewController(
        forExporting: [URL(fileURLWithPath: path)], asCopy: true
      )
    }
    picker.delegate = self
    picker.allowsMultipleSelection = selectingFiles && (args["allowMultiple"] as? Bool ?? false)
    activePicker = picker
    picker.presentationController?.delegate = self
    presenter.present(picker, animated: true)
  }

  private func presentingController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let activeWindows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
    let allWindows = scenes.flatMap(\.windows)
    let window = activeWindows.first(where: \.isKeyWindow)
      ?? activeWindows.first(where: { !$0.isHidden && $0.rootViewController != nil })
      ?? allWindows.first(where: \.isKeyWindow)
      ?? allWindows.first(where: { !$0.isHidden && $0.rootViewController != nil })
    guard var controller = window?.rootViewController else {
      return nil
    }
    while let presented = controller.presentedViewController {
      controller = presented
    }
    return controller
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard controller === activePicker else { return }
    guard let url = urls.first else {
      finish(nil)
      return
    }
    if selectingFiles {
      guard urls.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
        finish(FlutterError(code: "file_unreadable", message: "无法读取所选文件", details: nil))
        return
      }
      finish(urls.map { ["path": $0.path, "name": $0.lastPathComponent] })
    } else if selectingFolder {
      do {
        try startAccess(url)
        finish(url.standardizedFileURL.path)
      } catch {
        finish(FlutterError(
          code: "folder_access_denied", message: "无法访问所选文件夹", details: nil
        ))
      }
    } else {
      finish(url.absoluteString)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard controller === activePicker else { return }
    finish(nil)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard presentationController.presentedViewController === activePicker else { return }
    finish(nil)
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    selectingFolder = false
    selectingFiles = false
    activePicker = nil
    result?(value)
  }

  private func handleBookmarkCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "create":
        guard let path = args["path"] as? String else {
          throw FolderAccessError.missingGrant
        }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let url = activeURLs[key] else {
          throw FolderAccessError.missingGrant
        }
        result(try bookmarkData(url))
      case "resolve":
        guard let encoded = args["bookmark"] as? String,
              let data = Data(base64Encoded: encoded) else {
          throw FolderAccessError.invalidBookmark
        }
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: .withoutUI,
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        try startAccess(url)
        result([
          "path": url.standardizedFileURL.path,
          "bookmark": stale ? try bookmarkData(url) : encoded,
        ])
      case "forget":
        if let path = args["path"] as? String {
          let key = URL(fileURLWithPath: path).standardizedFileURL.path
          if let url = activeURLs.removeValue(forKey: key) {
            url.stopAccessingSecurityScopedResource()
          }
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(
        code: "bookmark_\(call.method)_failed", message: "文件夹授权失败，请重新选择目录", details: nil
      ))
    }
  }

  private func bookmarkData(_ url: URL) throws -> String {
    return try url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil
    ).base64EncodedString()
  }

  private func startAccess(_ url: URL) throws {
    let key = url.standardizedFileURL.path
    if activeURLs[key] != nil { return }
    guard url.startAccessingSecurityScopedResource() else {
      throw FolderAccessError.missingGrant
    }
    activeURLs[key] = url
  }

  deinit {
    for url in activeURLs.values {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private enum FolderAccessError: Error {
    case missingGrant
    case invalidBookmark
  }
}
