import AppKit
import RocketChatSDK

/// One server's custom emoji: the shortcode index (delta-synced from
/// `emoji-custom.list`) and the decoded images, loaded on first use.
@MainActor
@Observable
final class CustomEmojiStore {
    private(set) var index = CustomEmojiIndex()
    private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var scaled: [ScaledKey: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<URL> = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let client: RocketChatClient

    private struct ScaledKey: Hashable {
        let url: URL
        let height: CGFloat
    }

    init(client: RocketChatClient) {
        self.client = client
    }

    /// Pulls changes since the last sync. Failures are silent — the next
    /// activation retries, and unresolved shortcodes stay as text meanwhile.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard let delta = try? await client.customEmojis(updatedSince: index.watermark)
        else { return }
        if !delta.update.isEmpty || !delta.remove.isEmpty {
            index.apply(delta)
        }
    }

    /// The emoji's image scaled to `height` points, or nil while it loads (the
    /// load completing re-renders observers).
    func image(forShortCode shortCode: String, height: CGFloat) -> NSImage? {
        guard let emoji = index.emoji(forShortCode: shortCode) else { return nil }
        let url = client.customEmojiURL(emoji)
        guard let original = images[url] else {
            load(url)
            return nil
        }
        let key = ScaledKey(url: url, height: height)
        if let cached = scaled[key] { return cached }
        let image = Self.scale(original, toHeight: height)
        scaled[key] = image
        return image
    }

    private func load(_ url: URL) {
        guard inFlight.insert(url).inserted else { return }
        Task {
            defer { inFlight.remove(url) }
            // URLCache.shared honors the route's year-long max-age. The server
            // mislabels GIFs as JPEG, so NSImage sniffs the bytes instead.
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            images[url] = image
        }
    }

    private static func scale(_ image: NSImage, toHeight height: CGFloat) -> NSImage {
        let source = image.size
        guard source.height > 0 else { return image }
        let width = min(source.width * height / source.height, height * 3)
        let target = NSSize(width: width, height: height)
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}
