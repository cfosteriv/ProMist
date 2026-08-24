import SwiftUI

extension View {
    /// Retains Liquid Glass on iOS 26 while preserving the same prominence and
    /// interaction semantics on the application's iOS 17.6 deployment floor.
    @ViewBuilder
    func proMistGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
