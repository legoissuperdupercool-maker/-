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
