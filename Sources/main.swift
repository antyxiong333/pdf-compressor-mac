import SwiftUI
import Quartz
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Supported input image extensions (still images only).
let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]

// MARK: - Compression levels

enum CompressionLevel: String, CaseIterable, Identifiable {
    case high        // 高质量（轻度压缩）
    case recommended // 推荐（平衡）
    case strong      // 强力（体积最小）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "高质量"
        case .recommended: return "推荐"
        case .strong: return "强力压缩"
        }
    }

    var subtitle: String {
        switch self {
        case .high: return "轻度压缩 · 画质几乎无损"
        case .recommended: return "平衡体积与画质"
        case .strong: return "体积最小 · 适合分享"
        }
    }

    // PDF: quality 0–1, target DPI, max pixel dimension for embedded images.
    var pdfParams: (quality: Double, dpi: Int, maxPixels: Int) {
        switch self {
        case .high:        return (0.7, 150, 2400)
        case .recommended: return (0.5, 120, 1800)
        case .strong:      return (0.3, 96, 1200)
        }
    }

    // Image: JPEG quality 0–1, max pixel dimension (longest edge).
    var imageParams: (quality: Double, maxPixels: Int) {
        switch self {
        case .high:        return (0.8, 3000)
        case .recommended: return (0.6, 2200)
        case .strong:      return (0.4, 1600)
        }
    }
}

// MARK: - Shared result / errors

struct CompressResult {
    let originalBytes: Int
    let compressedBytes: Int
    let outputURL: URL
    let savedNothing: Bool  // original was kept because compression didn't help
}

enum CompressError: LocalizedError {
    case cannotOpen, filterFailed, writeFailed
    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "无法打开文件"
        case .filterFailed: return "压缩引擎初始化失败"
        case .writeFailed: return "无法写入输出文件"
        }
    }
}

func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
}

/// Build a non-colliding output URL like `dir/base_compressed.ext`.
func uniqueOutput(dir: URL, base: String, ext: String) -> URL {
    var candidate = dir.appendingPathComponent("\(base)_compressed.\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base)_compressed-\(n).\(ext)")
        n += 1
    }
    return candidate
}

// MARK: - PDF engine

enum PDFCompressor {
    static func compress(source src: URL, level: CompressionLevel) throws -> CompressResult {
        let p = level.pdfParams
        let originalBytes = fileSize(src)
        let dir = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfc-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runFilter(source: src, destination: tmp, params: p)
        let compressedBytes = fileSize(tmp)

        if compressedBytes > 0 && compressedBytes < originalBytes {
            let dst = uniqueOutput(dir: dir, base: base, ext: "pdf")
            try FileManager.default.copyItem(at: tmp, to: dst)
            return CompressResult(originalBytes: originalBytes, compressedBytes: compressedBytes,
                                  outputURL: dst, savedNothing: false)
        } else {
            let dst = uniqueOutput(dir: dir, base: base, ext: "pdf")
            try FileManager.default.copyItem(at: src, to: dst)
            return CompressResult(originalBytes: originalBytes, compressedBytes: originalBytes,
                                  outputURL: dst, savedNothing: true)
        }
    }

    private static func runFilter(source src: URL, destination dst: URL,
                                  params p: (quality: Double, dpi: Int, maxPixels: Int)) throws {
        guard let pdf = CGPDFDocument(src as CFURL) else { throw CompressError.cannotOpen }
        let props: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": p.quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": p.dpi,
                    "ImageScaleInterpolate": true,
                    "ImageSizeMax": p.maxPixels,
                    "ImageSizeMin": 0
                ]
            ]]],
            "FilterType": 1, "Name": "PDFCompressor"
        ]
        guard let filter = QuartzFilter(properties: props) else { throw CompressError.filterFailed }
        guard let consumer = CGDataConsumer(url: dst as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw CompressError.writeFailed }
        _ = filter.apply(to: ctx)
        for i in 1...max(1, pdf.numberOfPages) {
            guard let page = pdf.page(at: i) else { continue }
            var box = page.getBoxRect(.mediaBox)
            ctx.beginPage(mediaBox: &box)
            ctx.drawPDFPage(page)
            ctx.endPage()
        }
        ctx.closePDF()
    }
}

// MARK: - Image engine

enum ImageCompressor {
    static func compress(source src: URL, level: CompressionLevel) throws -> CompressResult {
        let p = level.imageParams
        let originalBytes = fileSize(src)
        let dir = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent

        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CompressError.cannotOpen
        }

        // Downsample the longest edge to maxPixels (high-quality, orientation-aware).
        let maxDim = max(cg.width, cg.height)
        let outImage: CGImage
        if maxDim > p.maxPixels {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: p.maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            outImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) ?? cg
        } else {
            outImage = cg
        }

        // Images with transparency stay PNG (lossless); everything else becomes JPEG.
        let a = cg.alphaInfo
        let hasAlpha = !(a == .none || a == .noneSkipLast || a == .noneSkipFirst)
        let outExt = hasAlpha ? "png" : "jpg"
        let outType = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgc-\(UUID().uuidString).\(outExt)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, outType, 1, nil) else {
            throw CompressError.writeFailed
        }
        var props: [CFString: Any] = [:]
        if !hasAlpha { props[kCGImageDestinationLossyCompressionQuality] = p.quality }
        CGImageDestinationAddImage(dest, outImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CompressError.writeFailed }

        let compressedBytes = fileSize(tmp)
        if compressedBytes > 0 && compressedBytes < originalBytes {
            let dst = uniqueOutput(dir: dir, base: base, ext: outExt)
            try FileManager.default.copyItem(at: tmp, to: dst)
            return CompressResult(originalBytes: originalBytes, compressedBytes: compressedBytes,
                                  outputURL: dst, savedNothing: false)
        } else {
            // keep original (same content, original extension)
            let dst = uniqueOutput(dir: dir, base: base, ext: src.pathExtension.isEmpty ? outExt : src.pathExtension)
            try FileManager.default.copyItem(at: src, to: dst)
            return CompressResult(originalBytes: originalBytes, compressedBytes: originalBytes,
                                  outputURL: dst, savedNothing: true)
        }
    }
}

// MARK: - Model

enum FileKind { case pdf, image }

enum ItemStatus: Equatable {
    case pending
    case working
    case done(saved: Double, bloatKept: Bool)
    case failed(String)
}

final class FileItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    @Published var status: ItemStatus = .pending
    @Published var originalBytes: Int
    @Published var compressedBytes: Int = 0
    @Published var outputURL: URL?

    init(url: URL, kind: FileKind) {
        self.url = url
        self.kind = kind
        self.originalBytes = fileSize(url)
    }
}

func kind(for url: URL) -> FileKind? {
    let ext = url.pathExtension.lowercased()
    if ext == "pdf" { return .pdf }
    if imageExtensions.contains(ext) { return .image }
    return nil
}

final class AppModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var level: CompressionLevel = .recommended
    @Published var isRunning = false

    func add(urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        for url in urls {
            guard let k = kind(for: url) else { continue }
            guard !existing.contains(url.standardizedFileURL) else { continue }
            items.append(FileItem(url: url, kind: k))
        }
    }

    func clear() { if !isRunning { items.removeAll() } }

    func remove(_ item: FileItem) {
        guard !isRunning else { return }
        items.removeAll { $0.id == item.id }
    }

    func compressAll() {
        guard !isRunning else { return }
        let pending = items.filter {
            if case .done = $0.status { return false }; return true
        }
        guard !pending.isEmpty else { return }
        isRunning = true
        let level = self.level

        DispatchQueue.global(qos: .userInitiated).async {
            for item in pending {
                DispatchQueue.main.async { item.status = .working }
                do {
                    let r: CompressResult
                    switch item.kind {
                    case .pdf:   r = try PDFCompressor.compress(source: item.url, level: level)
                    case .image: r = try ImageCompressor.compress(source: item.url, level: level)
                    }
                    let saved = r.originalBytes > 0
                        ? 1.0 - Double(r.compressedBytes) / Double(r.originalBytes) : 0
                    DispatchQueue.main.async {
                        item.compressedBytes = r.compressedBytes
                        item.outputURL = r.outputURL
                        item.status = .done(saved: max(0, saved), bloatKept: r.savedNothing)
                    }
                } catch {
                    DispatchQueue.main.async { item.status = .failed(error.localizedDescription) }
                }
            }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
}

// MARK: - Helpers

func humanSize(_ bytes: Int) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
}

// MARK: - Views

@main
struct PDFCompressorApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("PDF / 图片 压缩") {
            ContentView().environmentObject(model)
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty { dropZone } else { fileList }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper").font(.system(size: 26)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("PDF / 图片 压缩").font(.title2.bold())
                Text("本地压缩 · 文件不上传 · 支持 PDF 与图片")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc").font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("把 PDF 或图片拖到这里").font(.headline)
            Text("支持 PDF · JPG · PNG · HEIC · TIFF")
                .font(.caption).foregroundStyle(.secondary)
            Button("选择文件…") { pickFiles() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(16)
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 8) { ForEach(model.items) { FileRow(item: $0) } }
                .padding(16)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .overlay(alignment: .top) {
            if isTargeted {
                Text("松开以添加").padding(8).background(.thinMaterial, in: Capsule()).padding(.top, 8)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(CompressionLevel.allCases) { lvl in
                    LevelChip(level: lvl, selected: model.level == lvl) {
                        if !model.isRunning { model.level = lvl }
                    }
                }
            }
            HStack {
                if !model.items.isEmpty {
                    Button("清空") { model.clear() }.disabled(model.isRunning)
                    Button("添加…") { pickFiles() }.disabled(model.isRunning)
                }
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button(action: { model.compressAll() }) {
                    Text(model.isRunning ? "压缩中…" : "开始压缩").frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.items.isEmpty || model.isRunning)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(); var urls: [URL] = []; let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.add(urls: urls) }
        return true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        if panel.runModal() == .OK { model.add(urls: panel.urls) }
    }
}

struct LevelChip: View {
    let level: CompressionLevel
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(level.title).font(.subheadline.weight(.semibold))
                Text(level.subtitle).font(.system(size: 10))
                    .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct FileRow: View {
    @ObservedObject var item: FileItem
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .pdf ? "doc.text" : "photo")
                .font(.system(size: 22)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent).lineLimit(1).font(.callout.weight(.medium))
                statusLine
            }
            Spacer()
            trailing
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private var statusLine: some View {
        switch item.status {
        case .pending:
            Text(humanSize(item.originalBytes)).font(.caption).foregroundStyle(.secondary)
        case .working:
            Text("压缩中…").font(.caption).foregroundStyle(.secondary)
        case .done(let saved, let bloatKept):
            if bloatKept {
                Text("\(humanSize(item.originalBytes)) · 已是最优，无需压缩")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(humanSize(item.originalBytes)) → \(humanSize(item.compressedBytes)) · 省 \(Int(saved * 100))%")
                    .font(.caption).foregroundStyle(.green)
            }
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button {
                    if let out = item.outputURL { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).help("在访达中显示")
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .pending:
            Button { model.remove(item) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).disabled(model.isRunning)
        }
    }
}
