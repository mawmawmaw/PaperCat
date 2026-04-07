import SwiftUI

struct AdjustmentsView: View {
    @EnvironmentObject var viewModel: ScannerViewModel

    var body: some View {
        if let index = viewModel.selectedPageIndex,
           viewModel.document.pages.indices.contains(index) {
            let page = Binding(
                get: { viewModel.document.pages[index] },
                set: { viewModel.document.pages[index] = $0 }
            )

            VStack(spacing: 8) {
                HStack {
                    Text("Adjustments")
                        .font(.headline)
                    Spacer()
                    Button("Reset") {
                        viewModel.resetAdjustments(for: index)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                HStack(spacing: 20) {
                    adjustmentSlider(
                        label: "Brightness",
                        icon: "sun.max",
                        value: page.brightness,
                        range: -0.5...0.5,
                        onCommit: { viewModel.applyAdjustments(to: index) }
                    )

                    adjustmentSlider(
                        label: "Contrast",
                        icon: "circle.lefthalf.filled",
                        value: page.contrast,
                        range: 0.5...2.0,
                        onCommit: { viewModel.applyAdjustments(to: index) }
                    )

                    adjustmentSlider(
                        label: "Sharpness",
                        icon: "triangle",
                        value: page.sharpness,
                        range: 0.0...2.0,
                        onCommit: { viewModel.applyAdjustments(to: index) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func adjustmentSlider(
        label: String,
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(label)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range) { editing in
                if !editing {
                    onCommit()
                }
            }
        }
    }
}
