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

    /// The look in use (set by AppModel).
    static var look: UITheme = .theater
    /// The page colour of the look.
    static var cinemaBg: Color {
        switch look {
        case .premium: return Color(hex: 0x0F171E)
        case .wonder: return Color(hex: 0x060B1E)
        case .glass: return Color(hex: 0x050506)
        default: return Color(hex: 0x141414)
        }
    }
    /// Corner radius of cards in the look.
    static var cardRadius: CGFloat {
        switch look {
        case .wonder: return 10
        case .glass: return 14
        default: return 6
        }
    }
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

/// The page behind the cinema screens: each look has its own.
struct LookBackground: View {
    var body: some View {
        ZStack {
            Theme.cinemaBg
            switch Theme.look {
            case .premium:
                LinearGradient(colors: [Color(hex: 0x1B2A38).opacity(0.9), .clear], startPoint: .top, endPoint: .center)
            case .wonder:
                LinearGradient(colors: [Color(hex: 0x1A2350), Color(hex: 0x0B1030).opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                Stars()
            case .glass:
                RadialGradient(colors: [Color(hex: 0x2B3150).opacity(0.75), .clear], center: .top, startRadius: 20, endRadius: 900)
                RadialGradient(colors: [Color(hex: 0x40243F).opacity(0.45), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 700)
            default:
                EmptyView()
            }
        }
    }
}

/// A calm star field (the same stars every time).
struct Stars: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 42
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(UInt64(1) << 31)
            }
            for _ in 0..<140 {
                let x = next() * size.width, y = next() * size.height * 0.7
                let r = 0.4 + next() * 1.3
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.25 + next() * 0.55)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The start-up animation, the same as the Windows app's: a blue planet rises out of the
/// dark, its edge lights up from the middle outward with a flash, the letters come up one by
/// one, the "o" fills with blue and the logo glows once. Tap to skip.
struct LogoIntro: View {
    let done: () -> Void
    // Scene in the Windows app's units (1672 × 941, filled like "slice").
    private static let rx: CGFloat = 1500, ry: CGFloat = 1333, cx: CGFloat = 836, cy: CGFloat = 1900
    private static let top: CGFloat = cy - ry

    @State private var planet = false
    @State private var edge: CGFloat = 0
    @State private var flare = 0
    @State private var letters = [false, false, false, false]
    @State private var tint = false
    @State private var shine = false
    @State private var leaving = false

    var body: some View {
        GeometryReader { geo in
            let scale = max(geo.size.width / 1672, geo.size.height / 941)
            ZStack(alignment: .topLeading) {
                // 1. The planet.
                Ellipse()
                    .fill(RadialGradient(stops: [
                        .init(color: Color(hex: 0x2A86F2), location: 0),
                        .init(color: Color(hex: 0x0C46B8), location: 0.38),
                        .init(color: Color(hex: 0x03144A), location: 0.72),
                        .init(color: Color(hex: 0x010614), location: 1)
                    ], center: UnitPoint(x: 0.5, y: (980 - Self.top) / (2 * Self.ry)), startRadius: 0, endRadius: 760))
                    .frame(width: 2 * Self.rx, height: 2 * Self.ry)
                    .position(x: Self.cx, y: Self.cy)
                    .offset(y: planet ? 0 : 70)
                    .opacity(planet ? 1 : 0)
                // 2. Its edge, from the middle outward.
                ZStack {
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        let arc = Self.arc(side: side)
                        arc.trim(from: 0, to: edge).stroke(Self.edgeGradient, style: StrokeStyle(lineWidth: 10, lineCap: .round)).blur(radius: 7)
                        arc.trim(from: 0, to: edge).stroke(Self.edgeGradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    }
                }
                .frame(width: 1672, height: 941)
                Circle()
                    .fill(Color(hex: 0x7FE3FF))
                    .frame(width: 120, height: 120)
                    .blur(radius: 7)
                    .scaleEffect(x: [0.2, 1.4, 4][flare], y: [0.2, 0.6, 0.3][flare])
                    .opacity(flare == 1 ? 0.9 : 0)
                    .position(x: Self.cx, y: Self.top)
                // 3. The letters, one by one; 4. the "o" fills with blue.
                ZStack {
                    ForEach(Array(["intro-e", "intro-l1", "intro-l2", "intro-o"].enumerated()), id: \.offset) { i, name in
                        Image(name).resizable()
                            .opacity(letters[i] ? 1 : 0)
                            .offset(y: letters[i] ? 0 : 30)
                            .blur(radius: letters[i] ? 0 : 9)
                    }
                    Image("intro-otint").resizable().opacity(tint ? 1 : 0)
                }
                .frame(width: 545, height: 246)
                .shadow(color: Color(red: 80 / 255, green: 180 / 255, blue: 1).opacity(shine ? 0.8 : 0), radius: 30)
                .position(x: 560 + 545 / 2, y: 311 + 246 / 2)
            }
            .frame(width: 1672, height: 941)
            .scaleEffect(scale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear(perform: play)
    }

    /// One half of the planet's edge, from its top to where it leaves the scene.
    private static func arc(side: Double) -> Path {
        let a = Double(asin(636 / rx))
        return Path { p in
            for i in 0...60 {
                let t = -Double.pi / 2 + side * a * Double(i) / 60
                let pt = CGPoint(x: cx + rx * CGFloat(cos(t)), y: cy + ry * CGFloat(sin(t)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private static let edgeGradient = LinearGradient(stops: [
        .init(color: Color(hex: 0x1450D0).opacity(0), location: 0),
        .init(color: Color(hex: 0x1458E0), location: 0.22),
        .init(color: Color(hex: 0x3AD6FF), location: 0.5),
        .init(color: Color(hex: 0x1458E0), location: 0.78),
        .init(color: Color(hex: 0x1450D0).opacity(0), location: 1)
    ], startPoint: UnitPoint(x: 200.0 / 1672, y: 0), endPoint: UnitPoint(x: 1472.0 / 1672, y: 0))

    private func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

    private func play() {
        after(0.1) { withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 1.5)) { planet = true } }
        after(0.55) { withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: 1.1)) { edge = 1 } }
        after(0.5) { withAnimation(.easeOut(duration: 0.3)) { flare = 1 } }
        after(0.8) { withAnimation(.easeOut(duration: 0.9)) { flare = 2 } }
        for i in 0..<4 {
            after(1.05 + 0.12 * Double(i)) { withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.75)) { letters[i] = true } }
        }
        after(1.95) { withAnimation(.easeInOut(duration: 0.8)) { tint = true } }
        after(2.2) { withAnimation(.easeInOut(duration: 0.45)) { shine = true } }
        after(2.65) { withAnimation(.easeInOut(duration: 0.45)) { shine = false } }
        after(2.7) { finish() }
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(.easeIn(duration: 0.5)) { leaving = true }
        after(0.5) { done() }
    }
}
