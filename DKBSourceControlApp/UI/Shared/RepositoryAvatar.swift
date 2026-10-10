import AppKit
import DKBSourceControlCore
import SwiftUI

/// A repository's picture, round like a contact's: the image the user chose,
/// or the initials of its name on a colour of its own.
struct RepositoryAvatar: View {
    let model: RepositoryModel
    var size: CGFloat = 24

    /// Picked from the record's id, so a rename keeps the colour.
    private static let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .red, .teal, .indigo, .mint, .brown]

    var body: some View {
        Group {
            if let image = model.avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // Logos are often drawn for a white page.
                    .background(.white)
            } else {
                let color = Self.colors[Self.stableIndex(model.id, count: Self.colors.count)]
                LinearGradient(colors: [color.opacity(0.7), color], startPoint: .top, endPoint: .bottom)
                    .overlay {
                        Text(verbatim: model.record.initials)
                            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.5)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// `hashValue` changes from launch to launch; this doesn't.
    private static func stableIndex(_ text: String, count: Int) -> Int {
        Int(text.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % UInt32(count))
    }

    /// The picture as stored: 256 × 256 PNG. A roughly square image fills
    /// it, centred, as Contacts crops a photo; a wide or tall one (a
    /// wordmark) is fitted whole on a transparent background.
    static func png(from url: URL) -> Data? {
        let side = 256
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let ratio = image.size.width / image.size.height
        let fill = (0.8...1.25).contains(ratio)
        let scale = (fill ? max : min)(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Choose Image… and Remove Image, in a repository's menu in the sidebar
/// and on the Dashboard.
struct AvatarMenuItems: View {
    let list: RepositoryList
    let model: RepositoryModel

    var body: some View {
        Button("Choose Image…", action: choose)
        if model.record.avatar != nil {
            Button("Remove Image") { list.setAvatar(model, to: nil) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a picture or logo for “\(model.record.name)”", bundle: AppLocale.bundle)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let png = RepositoryAvatar.png(from: url) {
            list.setAvatar(model, to: png)
        } else {
            let alert = NSAlert()
            alert.messageText = String(localized: "The image couldn't be read", bundle: AppLocale.bundle)
            alert.informativeText = url.lastPathComponent
            alert.runModal()
        }
    }
}
