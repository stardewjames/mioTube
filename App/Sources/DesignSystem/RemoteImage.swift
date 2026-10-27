import ImageIO
import MioTubeCore
import SwiftUI
import UIKit

/// Downsampling image loader: memory `NSCache` (100 MB cost), disk cache under
/// `Caches/MioTube/images`, at most 6 downloads in flight, identical requests coalesced.
actor ImagePipeline {
  private let memory = NSCache<NSString, UIImage>()
  private let session: URLSession
  private let directory: URL
  private var inFlight: [String: Task<UIImage?, Never>] = [:]
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private static let maxConcurrent = 6

  init() {
    memory.totalCostLimit = 100 << 20
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 6
    config.urlCache = nil
    session = URLSession(configuration: config)
    directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MioTube/images", isDirectory: true)
  }

  /// Cached decode without starting a download (used for artwork).
  func cachedImage(for url: URL) -> UIImage? {
    memory.object(forKey: url.absoluteString as NSString)
  }

  func image(for url: URL, target: CGSize, scale: CGFloat) async -> UIImage? {
    let pixels = Int(max(target.width, target.height) * scale)
    let key = "\(url.absoluteString)#\(pixels)"
    if let hit = memory.object(forKey: key as NSString) { return hit }
    if let task = inFlight[key] { return await task.value }
    let task = Task { await self.load(url: url, maxPixels: pixels) }
    inFlight[key] = task
    let image = await task.value
    inFlight[key] = nil
    if let image {
      memory.setObject(image, forKey: key as NSString, cost: Self.cost(image))
      memory.setObject(image, forKey: url.absoluteString as NSString, cost: Self.cost(image))
    }
    return image
  }

  func clearDisk() {
    try? FileManager.default.removeItem(at: directory)
    memory.removeAllObjects()
  }

  private func load(url: URL, maxPixels: Int) async -> UIImage? {
    let file = diskURL(for: url)
    if let data = try? Data(contentsOf: file) {
      return Self.decode(data, maxPixels: maxPixels)
    }
    await acquire()
    defer { release() }
    guard let (data, response) = try? await session.data(from: url),
          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
    return Self.decode(data, maxPixels: maxPixels)
  }

  private func diskURL(for url: URL) -> URL {
    let hash = sha256Hex(url.absoluteString)
    return directory.appendingPathComponent(String(hash.prefix(2)), isDirectory: true).appendingPathComponent(hash + ".img")
  }

  private func acquire() async {
    if active < Self.maxConcurrent {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      active -= 1
    } else {
      waiters.removeFirst().resume()
    }
  }

  nonisolated static func decode(_ data: Data, maxPixels: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  nonisolated static func cost(_ image: UIImage) -> Int {
    guard let cg = image.cgImage else { return 1 }
    return cg.bytesPerRow * cg.height
  }
}

/// Never `AsyncImage`: decodes off-main at the displayed size.
struct RemoteImage: View {
  let url: URL?
  var contentMode: ContentMode = .fill

  @Environment(AppEnvironment.self) private var env
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?
  @State private var loadedURL: URL?

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Rectangle().fill(Color(.secondarySystemFill))
        if let image {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .transition(.opacity)
        }
      }
      .task(id: TaskKey(url: url, size: proxy.size)) {
        guard let url, proxy.size.width > 0 else { return }
        if loadedURL != url { image = nil }
        let loaded = await env.images.image(for: url, target: proxy.size, scale: displayScale)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          image = loaded
          loadedURL = url
        }
      }
    }
  }

  private struct TaskKey: Equatable {
    let url: URL?
    let size: CGSize
  }
}
