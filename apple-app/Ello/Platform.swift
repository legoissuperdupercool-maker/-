import SwiftUI

// Small differences between iPad/iPhone and Apple TV, kept in one place.

extension View {
    /// Hides the status bar (iPad/iPhone; Apple TV has none).
    @ViewBuilder func hideStatusBar() -> some View {
        #if os(iOS)
        self.statusBarHidden()
        #else
        self
        #endif
    }
}

extension ProgressView {
    /// A big spinner where the platform has sizes.
    @ViewBuilder func bigSpinner() -> some View {
        #if os(iOS)
        self.controlSize(.large)
        #else
        self
        #endif
    }
}

extension DynamicViewContent {
    /// Swipe to delete on iPad/iPhone; Apple TV removes things another way.
    @ViewBuilder func deletable(_ action: @escaping (IndexSet) -> Void) -> some View {
        #if os(iOS)
        self.onDelete(perform: action)
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// Apple TV has no photo library: the photo buttons simply don't show there.
struct PhotosPickerItem: Equatable {
    func loadTransferable<T>(type: T.Type) async throws -> T? { nil }
}

struct PhotoFilter {
    static let images = PhotoFilter()
}

struct PhotosPicker<Label: View>: View {
    init(selection: Binding<PhotosPickerItem?>, matching: PhotoFilter, @ViewBuilder label: () -> Label) {}
    var body: some View { EmptyView() }
}
#endif

/// Buttons without a frame of their own. On iPad they dim when pressed; on Apple TV the
/// selected one grows a little with a glow and a ring in the look's colour, instead of the
/// system's white block.
struct ElloButtonStyle: ButtonStyle {
    var ring = true
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, ring: ring) }

    struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let ring: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            #if os(tvOS)
            configuration.label
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 18, y: 8)
                .overlay {
                    if ring && focused {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.blue, lineWidth: 4).padding(-8)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: focused)
            #else
            configuration.label
                .opacity(configuration.isPressed ? 0.7 : 1)
            #endif
        }
    }
}

extension ButtonStyle where Self == ElloButtonStyle {
    static var ello: ElloButtonStyle { ElloButtonStyle() }
    /// Same, without the ring (posters, menu icons: they grow and glow only).
    static var elloPlain: ElloButtonStyle { ElloButtonStyle(ring: false) }
}

/// Sizes on a TV: everything is seen from the couch, so text, cards and spacing are bigger.
enum UI {
    #if os(tvOS)
    static let s: CGFloat = 1.6
    #else
    static let s: CGFloat = 1
    #endif
    /// Side margin of pages.
    static var margin: CGFloat { 28 * s * (s > 1 ? 1.3 : 1) }
}
