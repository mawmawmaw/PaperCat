import SwiftUI

enum AnnotationMode {
    case none
    case text
    case draw
}

struct AnnotationOverlay: View {
    @Binding var annotations: [Annotation]
    let imageSize: CGSize
    let displaySize: CGSize
    let mode: AnnotationMode

    // Shared settings
    @State private var selectedColor: Color = .red
    @State private var fontSize: CGFloat = 16
    @State private var strokeWidth: CGFloat = 3

    // Editing state
    @State private var editingTextID: UUID?
    @State private var editingText: String = ""
    @State private var currentStroke: [CGPoint] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Existing annotations
            ForEach(annotations) { annotation in
                switch annotation {
                case .text(let t):
                    textAnnotationView(t)
                case .drawing(let d):
                    drawingPath(d)
                }
            }

            // Current drawing stroke
            if mode == .draw && !currentStroke.isEmpty {
                Path { path in
                    let points = currentStroke.map { denormalize($0) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(selectedColor, lineWidth: strokeWidth)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped() // Prevent drawing outside document bounds
        .contentShape(Rectangle())
        .gesture(mode == .draw ? drawGesture : nil)
        .onTapGesture { location in
            if editingTextID != nil {
                commitCurrentEdit()
            } else if mode == .text {
                addTextAnnotation(at: location)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if mode != .none {
                toolSettingsBar
                    .padding(8)
            }
        }
    }

    // MARK: - Settings Bar

    private var toolSettingsBar: some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: $selectedColor)
                .labelsHidden()
                .frame(width: 28)

            if mode == .text {
                Picker("Size", selection: $fontSize) {
                    Text("S").tag(CGFloat(12))
                    Text("M").tag(CGFloat(16))
                    Text("L").tag(CGFloat(22))
                    Text("XL").tag(CGFloat(30))
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            if mode == .draw {
                HStack(spacing: 6) {
                    ForEach([(CGFloat(2), "Thin"), (CGFloat(4), "Med"), (CGFloat(7), "Thick")], id: \.0) { width, label in
                        Button(action: { strokeWidth = width }) {
                            Text(label)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(strokeWidth == width ? selectedColor.opacity(0.2) : Color.clear)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Text Annotations

    private func textAnnotationView(_ t: TextAnnotation) -> some View {
        let pos = denormalize(t.position)
        return Group {
            if editingTextID == t.id {
                HStack(spacing: 4) {
                    TextField("Type here...", text: $editingText)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize))
                        .foregroundStyle(selectedColor)
                        .frame(minWidth: 80, maxWidth: 250)
                        .fixedSize()
                        .onSubmit { commitCurrentEdit() }

                    Button(action: { commitCurrentEdit() }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)

                    Button(action: { cancelEdit(id: t.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.black.opacity(0.6), lineWidth: 1.5)
                )
                .cornerRadius(4)
                .shadow(color: .black.opacity(0.2), radius: 3, x: 1, y: 1)
                .position(x: pos.x, y: pos.y)
            } else {
                HStack(spacing: 3) {
                    Text(t.text)
                        .font(.system(size: t.fontSize))
                        .foregroundColor(Color(nsColor: t.color))

                    Button(action: { deleteAnnotation(id: t.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.9))
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(nsColor: t.color).opacity(0.5), lineWidth: 1)
                )
                .fixedSize()
                .position(x: pos.x, y: pos.y)
                .onTapGesture {
                    editingTextID = t.id
                    editingText = t.text
                    fontSize = t.fontSize
                    selectedColor = Color(nsColor: t.color)
                }
            }
        }
    }

    private func addTextAnnotation(at displayPoint: CGPoint) {
        let normalized = normalize(displayPoint)
        let newText = TextAnnotation(
            text: "",
            position: normalized,
            fontSize: fontSize,
            color: NSColor(selectedColor)
        )
        annotations.append(.text(newText))
        editingTextID = newText.id
        editingText = ""
    }

    private func commitCurrentEdit() {
        guard let id = editingTextID else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            annotations.removeAll { $0.id == id }
        } else if let idx = annotations.firstIndex(where: { $0.id == id }) {
            if case .text(var t) = annotations[idx] {
                t.text = trimmed
                t.fontSize = fontSize
                t.color = NSColor(selectedColor)
                annotations[idx] = .text(t)
            }
        }
        editingTextID = nil
        editingText = ""
    }

    private func cancelEdit(id: UUID) {
        if let idx = annotations.firstIndex(where: { $0.id == id }) {
            if case .text(let t) = annotations[idx], t.text.isEmpty {
                annotations.remove(at: idx)
            }
        }
        editingTextID = nil
        editingText = ""
    }

    private func deleteAnnotation(id: UUID) {
        annotations.removeAll { $0.id == id }
    }

    // MARK: - Drawing

    private func drawingPath(_ d: DrawingAnnotation) -> some View {
        Path { path in
            let points = d.points.map { denormalize($0) }
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(Color(nsColor: d.color), lineWidth: d.lineWidth)
        .contentShape(Path { path in
            let points = d.points.map { denormalize($0) }
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }.strokedPath(StrokeStyle(lineWidth: max(d.lineWidth * 3, 12))))
        .contextMenu {
            Button("Delete", role: .destructive) {
                deleteAnnotation(id: d.id)
            }
        }
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Clamp to document bounds
                let clamped = CGPoint(
                    x: max(0, min(value.location.x, displaySize.width)),
                    y: max(0, min(value.location.y, displaySize.height))
                )
                let normalized = normalize(clamped)
                if currentStroke.isEmpty {
                    let start = CGPoint(
                        x: max(0, min(value.startLocation.x, displaySize.width)),
                        y: max(0, min(value.startLocation.y, displaySize.height))
                    )
                    currentStroke.append(normalize(start))
                }
                currentStroke.append(normalized)
            }
            .onEnded { _ in
                if currentStroke.count > 1 {
                    let drawing = DrawingAnnotation(
                        points: currentStroke,
                        lineWidth: strokeWidth,
                        color: NSColor(selectedColor)
                    )
                    annotations.append(.drawing(drawing))
                }
                currentStroke = []
            }
    }

    // MARK: - Coordinate Conversion

    private func normalize(_ displayPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: displayPoint.x / displaySize.width,
            y: displayPoint.y / displaySize.height
        )
    }

    private func denormalize(_ normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: normalizedPoint.x * displaySize.width,
            y: normalizedPoint.y * displaySize.height
        )
    }
}
