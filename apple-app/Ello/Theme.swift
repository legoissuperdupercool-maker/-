import SwiftUI

/// ello's colours (same as the Windows app).
enum Theme {
    static let bg = Color(hex: 0x0E1013)
    static let surface = Color(hex: 0x1C1F24)
    static let surface2 = Color(hex: 0x262A31)
    static let text = Color(hex: 0xE8EAED)
    static let dim = Color(hex: 0x9AA0A6)
    static let faint = Color(hex: 0x6B7076)
    /// The active profile's theme colour (set by AppModel when the profile changes).
    static var accentHex: UInt32 = 0x4C8DFF
    static var blue: Color { Color(hex: accentHex) }
    /// Black or white, whichever reads better on the accent.
    static var onAccent: Color {
        let r = Double((accentHex >> 16) & 0xFF), g = Double((accentHex >> 8) & 0xFF), b = Double(accentHex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 170 ? .black : .white
    }

    static let accents: [(id: String, name: String, hex: UInt32)] = [
        ("blue", "ello blue", 0x4C8DFF), ("red", "Cinema red", 0xE50914), ("purple", "Purple", 0x9B5CFF),
        ("pink", "Pink", 0xFF3D8B), ("orange", "Orange", 0xFF7A1A), ("gold", "Gold", 0xF5B400),
        ("green", "Green", 0x1FC65F), ("teal", "Teal", 0x14C2B0)
    ]
    static func accentValue(_ id: String?) -> UInt32 { accents.first { $0.id == id }?.hex ?? accents[0].hex }

    /// Cinema look: near-black page.
    static let cinemaBg = Color(hex: 0x141414)
    static let good = Color(hex: 0x34C759)
    static let bad = Color(hex: 0xFF453A)
    static let palette: [Color] = [0x1A73E8, 0xD93025, 0x188038, 0x9334E6, 0xE8710A, 0x007B83, 0xC5221F, 0xA142F4].map { Color(hex: $0) }

    static let profileColors: [UInt32] = [0x1A73E8, 0xD93025, 0x188038, 0x9334E6, 0xE8710A, 0x007B83, 0xE52592, 0xF9AB00]

    static func color(for name: String) -> Color {
        var h: UInt32 = 0
        for u in name.unicodeScalars { h = h &* 31 &+ u.value }
        return palette[Int(h % UInt32(palette.count))]
    }

    static var background: some View {
        ZStack {
            bg
            RadialGradient(colors: [blue.opacity(0.16), .clear], center: .topLeading, startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Pill button, like the Windows app's.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 22)
            .frame(height: 46)
            .foregroundStyle(primary ? Color.black : Theme.text)
            .background(primary ? Theme.text : Color.white.opacity(0.12), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Artwork with a calm coloured placeholder (initials) while it loads or if it's missing.
struct Artwork: View {
    let url: String?
    let name: String
    var contentMode: ContentMode = .fill

    var body: some View {
        ZStack {
            Theme.color(for: name).opacity(0.85)
            Text(initials)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
            if let url, let u = URL(string: url) {
                AsyncImage(url: u, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: contentMode)
                    }
                }
            }
        }
        .clipped()
    }

    private var initials: String {
        let clean = name.replacingOccurrences(of: #"^\s*\[?[A-Z]{2,3}\]?\s*[-|:•]\s*"#, with: "", options: .regularExpression)
        return clean.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
