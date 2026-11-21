import SwiftUI

/// The start of the app: the camera, looking for the set's box. Once its barcode (or its item
/// or set number) is seen, the app opens.
struct BoxScanView: View {
    @Environment(AppModel.self) private var app
    @State private var scanner = BoxScanner()

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let image = scanner.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            Group {
                switch scanner.state {
                case .found:
                    StatusChip(symbol: "checkmark.seal.fill", text: "Set \(BuildConfig.setNumber) found", tint: Theme.Palette.green)
                case .noCamera:
                    StatusChip(symbol: "video.slash", text: "No camera", tint: Theme.Palette.red)
                default:
                    ScanHint()
                }
            }
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.state) { _, state in
            guard state == .found else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                app.setScanned = true
            }
        }
    }
}
