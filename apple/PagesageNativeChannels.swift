import CoreGraphics
import Foundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - PDF rasterization

enum PagesagePdfError: Error {
  case fileNotFound
  case pageOutOfRange
  case renderFailed(String)
}

struct PagesageRenderedImage {
  let image: CGImage
  let width: Int
  let height: Int
}

struct PagesageRenderedPage {
  let data: Data
  let width: Int
  let height: Int
}

enum PagesagePdfPageRenderer {
  /// Mirrors the Windows render budget: DPI and longest-edge limits, capped at
  /// 5,000,000 pixels so a scanned page cannot exhaust memory.
  static func renderImage(
    path: String,
    pageNumber: Int,
    dpi: Int,
    maxEdge: Int,
    maxPixels: Int
  ) throws -> PagesageRenderedImage {
    guard FileManager.default.fileExists(atPath: path) else {
      throw PagesagePdfError.fileNotFound
    }
    guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else {
      throw PagesagePdfError.renderFailed("无法打开 PDF 文件")
    }
    guard pageNumber >= 1,
          pageNumber <= document.numberOfPages,
          let page = document.page(at: pageNumber) else {
      throw PagesagePdfError.pageOutOfRange
    }
    let cropBox = page.getBoxRect(.cropBox)
    let usesCropBox = cropBox.width > 0 && cropBox.height > 0
    let box = usesCropBox ? cropBox : page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else {
      throw PagesagePdfError.renderFailed("PDF 页面尺寸无效")
    }

    let rotation = ((page.rotationAngle % 360) + 360) % 360
    let isQuarterTurn = rotation == 90 || rotation == 270
    let effectiveWidth = isQuarterTurn ? box.height : box.width
    let effectiveHeight = isQuarterTurn ? box.width : box.height
    let longest = max(effectiveWidth, effectiveHeight)
    let scale = min(
      Double(max(dpi, 1)) / 72.0,
      Double(max(maxEdge, 1)) / Double(longest)
    )
    var width = Double(effectiveWidth) * scale
    var height = Double(effectiveHeight) * scale
    let pixelBudget = max(1, min(maxPixels, 5_000_000))
    if width * height > Double(pixelBudget) {
      let factor = sqrt(Double(pixelBudget) / (width * height))
      width *= factor
      height *= factor
    }
    let pixelWidth = max(1, Int(width.rounded()))
    let pixelHeight = max(1, Int(height.rounded()))

    guard let context = CGContext(
      data: nil,
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
      throw PagesagePdfError.renderFailed("无法创建页面图像")
    }
    // JPEG has no alpha channel; paint white so transparent scans stay legible
    // instead of turning black.
    context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.interpolationQuality = .high
    let target = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(pixelWidth),
      height: CGFloat(pixelHeight)
    )
    context.concatenate(
      page.getDrawingTransform(
        usesCropBox ? .cropBox : .mediaBox,
        rect: target,
        rotate: 0,
        preserveAspectRatio: true
      )
    )
    context.drawPDFPage(page)
    guard let image = context.makeImage() else {
      throw PagesagePdfError.renderFailed("无法生成页面图像")
    }
    return PagesageRenderedImage(
      image: image,
      width: pixelWidth,
      height: pixelHeight
    )
  }

  static func renderPage(
    path: String,
    pageNumber: Int,
    dpi: Int,
    maxEdge: Int,
    maxPixels: Int,
    format: String,
    quality: Int
  ) throws -> PagesageRenderedPage {
    let rendered = try renderImage(
      path: path,
      pageNumber: pageNumber,
      dpi: dpi,
      maxEdge: maxEdge,
      maxPixels: maxPixels
    )
    let data = try encode(
      rendered.image,
      png: format.lowercased() == "png",
      quality: quality
    )
    return PagesageRenderedPage(
      data: data,
      width: rendered.width,
      height: rendered.height
    )
  }

  private static func encode(
    _ image: CGImage,
    png: Bool,
    quality: Int
  ) throws -> Data {
    let output = NSMutableData()
    let type = png ? UTType.png.identifier : UTType.jpeg.identifier
    guard let destination = CGImageDestinationCreateWithData(
      output,
      type as CFString,
      1,
      nil
    ) else {
      throw PagesagePdfError.renderFailed("无法编码页面图像")
    }
    var options: [CFString: Any] = [:]
    if !png {
      options[kCGImageDestinationLossyCompressionQuality] =
        Double(min(max(quality, 1), 100)) / 100.0
    }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw PagesagePdfError.renderFailed("无法编码页面图像")
    }
    return output as Data
  }
}

enum PagesagePdfRasterChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "pagesage/pdf_raster",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "renderPage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(
          code: "render_failed",
          message: "missing path",
          details: nil
        ))
        return
      }
      let pageNumber = args["pageNumber"] as? Int ?? 0
      let dpi = args["dpi"] as? Int ?? 200
      let maxEdge = args["maxEdge"] as? Int ?? 2200
      let maxPixels = args["maxPixels"] as? Int ?? 5_000_000
      let format = args["format"] as? String ?? "jpeg"
      let quality = args["quality"] as? Int ?? 85
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let rendered = try PagesagePdfPageRenderer.renderPage(
            path: path,
            pageNumber: pageNumber,
            dpi: dpi,
            maxEdge: maxEdge,
            maxPixels: maxPixels,
            format: format,
            quality: quality
          )
          DispatchQueue.main.async {
            result([
              "bytes": FlutterStandardTypedData(bytes: rendered.data),
              "width": rendered.width,
              "height": rendered.height,
            ])
          }
        } catch {
          let flutterError = PagesageNativeErrors.raster(error)
          DispatchQueue.main.async { result(flutterError) }
        }
      }
    }
  }
}

// MARK: - OCR

enum PagesageOcrError: Error {
  case failed(String)
  case unavailable(String)
  case languageUnavailable(String)
}

enum PagesageOcrEngine {
  #if os(iOS)
  static let engineId = "ios-vision"
  #else
  static let engineId = "macos-vision"
  #endif

  /// Vision's language list is fixed for the OS and expensive enough that
  /// probing it for every page would add avoidable latency.
  private static let cachedLanguages: [String] = {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    return (try? request.supportedRecognitionLanguages()) ?? []
  }()

  static func supportedLanguages() throws -> [String] {
    let languages = cachedLanguages
    if languages.isEmpty {
      throw PagesageOcrError.unavailable("当前系统没有可用的文字识别语言")
    }
    return languages
  }

  static func recognize(
    image: CGImage,
    languageHint: String
  ) throws -> [String: Any] {
    let hint = languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
    let requested = hint.isEmpty ? "zh-Hans" : hint
    let available = try supportedLanguages()
    guard let language = resolveLanguage(requested, available: available) else {
      throw PagesageOcrError.languageUnavailable(
        "当前系统不支持所选 OCR 语言（\(requested)）"
      )
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = [language]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      throw PagesageOcrError.unavailable(
        "本地文字识别失败：\(error.localizedDescription)"
      )
    }

    let imageWidth = max(image.width, 1)
    let imageHeight = max(image.height, 1)
    var lines: [String] = []
    var blocks: [[String: Any]] = []
    var confidenceTotal = 0.0
    var confidenceCount = 0
    // Line-level boxes keep native ::selection on one continuous range per
    // line, matching the EPUB/PDF.js feel. Word boxes read as islands.
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else {
        continue
      }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        continue
      }
      lines.append(text)
      confidenceTotal += Double(candidate.confidence)
      confidenceCount += 1
      // Vision uses a normalized bottom-left origin; Dart expects top-left.
      let box = observation.boundingBox
      blocks.append([
        "text": text,
        "left": clampUnit(box.origin.x),
        "top": clampUnit(1.0 - box.origin.y - box.size.height),
        "width": clampUnit(box.size.width),
        "height": clampUnit(box.size.height),
      ])
    }

    var payload: [String: Any] = [
      "text": lines.joined(separator: "\n"),
      "engine": engineId,
      "language": language,
      "imageWidth": imageWidth,
      "imageHeight": imageHeight,
      "blocks": blocks,
    ]
    if confidenceCount > 0 {
      payload["confidence"] = confidenceTotal / Double(confidenceCount)
    }
    return payload
  }

  /// Maps a BCP-47 hint onto a language Vision actually supports.
  static func resolveLanguage(
    _ requested: String,
    available: [String]
  ) -> String? {
    let normalized = requested
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
    let parts = normalized.split(separator: "-").map(String.init)
    guard let primary = parts.first, !primary.isEmpty else {
      return nil
    }
    if let exact = available.first(where: { $0.lowercased() == normalized }) {
      return exact
    }
    if primary == "zh" {
      let traditional = parts.contains("hant") || parts.contains("tw") ||
        parts.contains("hk") || parts.contains("mo")
      let target = traditional ? "zh-hant" : "zh-hans"
      if let match = available.first(where: {
        $0.lowercased().hasPrefix(target)
      }) {
        return match
      }
    }
    return available.first(where: {
      let tag = $0.lowercased()
      return tag == primary || tag.hasPrefix("\(primary)-")
    })
  }

  private static func clampUnit(_ value: CGFloat) -> Double {
    return min(max(Double(value), 0.0), 1.0)
  }
}

enum PagesageOcrChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "pagesage/ocr",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "isAvailable":
        runInBackground(result: result) {
          let languages = try? PagesageOcrEngine.supportedLanguages()
          return languages?.isEmpty == false
        }
      case "supportedLanguages":
        runInBackground(result: result) {
          try PagesageOcrEngine.supportedLanguages()
        }
      case "recognizePdfPage":
        let languageHint = args["languageHint"] as? String ?? "zh-Hans"
        let pageNumber = args["pageNumber"] as? Int ?? 0
        let dpi = args["dpi"] as? Int ?? 200
        let maxEdge = args["maxEdge"] as? Int ?? 2200
        guard let path = args["path"] as? String, !path.isEmpty else {
          result(FlutterError(
            code: "file_not_found",
            message: "missing path",
            details: nil
          ))
          return
        }
        runInBackground(result: result, mapError: PagesageNativeErrors.ocr) {
          let rendered = try PagesagePdfPageRenderer.renderImage(
            path: path,
            pageNumber: pageNumber,
            dpi: dpi,
            maxEdge: maxEdge,
            maxPixels: 5_000_000
          )
          return try PagesageOcrEngine.recognize(
            image: rendered.image,
            languageHint: languageHint
          )
        }
      case "recognize":
        let languageHint = args["languageHint"] as? String ?? "zh-Hans"
        guard let bytes = args["imageBytes"] as? FlutterStandardTypedData,
              let source = CGImageSourceCreateWithData(bytes.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
          result(FlutterError(
            code: "ocr_failed",
            message: "无法读取页面图像",
            details: nil
          ))
          return
        }
        runInBackground(result: result, mapError: PagesageNativeErrors.ocr) {
          try PagesageOcrEngine.recognize(
            image: image,
            languageHint: languageHint
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Runs CPU-heavy work off the platform thread and reports on it.
  private static func runInBackground<T>(
    result: @escaping FlutterResult,
    mapError: @escaping (Error) -> FlutterError = PagesageNativeErrors.ocr,
    work: @escaping () throws -> T
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try work()
        DispatchQueue.main.async { result(value) }
      } catch {
        let flutterError = mapError(error)
        DispatchQueue.main.async { result(flutterError) }
      }
    }
  }
}

enum PagesageNativeErrors {
  static func raster(_ error: Error) -> FlutterError {
    switch error {
    case PagesagePdfError.fileNotFound:
      return FlutterError(
        code: "file_not_found",
        message: "找不到 PDF 文件",
        details: nil
      )
    case PagesagePdfError.pageOutOfRange:
      return FlutterError(
        code: "page_out_of_range",
        message: "页码超出范围",
        details: nil
      )
    case PagesagePdfError.renderFailed(let message):
      return FlutterError(code: "render_failed", message: message, details: nil)
    default:
      return FlutterError(
        code: "render_failed",
        message: error.localizedDescription,
        details: nil
      )
    }
  }

  static func ocr(_ error: Error) -> FlutterError {
    switch error {
    case PagesageOcrError.languageUnavailable(let message):
      return FlutterError(
        code: "ocr_language_unavailable",
        message: message,
        details: nil
      )
    case PagesageOcrError.unavailable(let message):
      return FlutterError(
        code: "ocr_unavailable",
        message: message,
        details: nil
      )
    case PagesageOcrError.failed(let message):
      return FlutterError(code: "ocr_failed", message: message, details: nil)
    case PagesagePdfError.fileNotFound:
      return FlutterError(
        code: "file_not_found",
        message: "找不到 PDF 文件",
        details: nil
      )
    case PagesagePdfError.pageOutOfRange:
      return FlutterError(
        code: "page_out_of_range",
        message: "页码超出范围",
        details: nil
      )
    case PagesagePdfError.renderFailed(let message):
      return FlutterError(code: "ocr_failed", message: message, details: nil)
    default:
      return FlutterError(
        code: "ocr_failed",
        message: error.localizedDescription,
        details: nil
      )
    }
  }
}
