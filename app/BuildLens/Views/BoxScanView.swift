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
        // Always a way out to the home screen (the scan stays the first thing offered).
        .overlay(alignment: .topLeading) {
            Button {
                app.skippedBoxScan = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
                    .background(Theme.Palette.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(Theme.Spacing.md)
            .accessibilityLabel("Close")
        }
        .onAppear {
            scanner.start()
            app.wakeGlasses()
        }
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
