import SwiftUI
import PromptCore
import AppKit

/// The app mark: a prompt chevron with a cursor, and a spark that "improves" it.
/// Used in-app and rendered to the .icns at build time (`--render-icon`).
struct LogoMark: View {
    var size: CGFloat = 64

    private let spark = LinearGradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.30),
                                                Color(red: 1.0, green: 0.42, blue: 0.30)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: max(1, size * 0.012))

            Chevron()
                .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.20, height: size * 0.32)
                .offset(x: -size * 0.15, y: size * 0.06)

            Capsule()
                .fill(Color.white.opacity(0.38))
                .frame(width: size * 0.22, height: size * 0.085)
                .offset(x: size * 0.10, y: size * 0.18)

            Spark()
                .fill(spark)
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(x: size * 0.17, y: -size * 0.17)
        }
        .frame(width: size, height: size)
    }
}

private struct Chevron: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

/// Four-point star with concave sides.
struct Spark: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let pts = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                   CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        var p = Path()
        p.move(to: pts[0])
        for i in 1...4 { p.addQuadCurve(to: pts[i % 4], control: c) }
        p.closeSubpath()
        return p
    }
}

enum IconRenderer {
    /// macOS icon grid: 824pt artwork centered in a 1024 canvas, with a soft drop shadow.
    @MainActor
    static func render(iconset dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let art = ZStack {
            LogoMark(size: 824).shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
        .frame(width: 1024, height: 1024)

        let specs: [(String, CGFloat)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, px) in specs {
            let r = ImageRenderer(content: art)
            r.scale = px / 1024
            guard let cg = r.cgImage else { continue }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try? png?.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }
}
