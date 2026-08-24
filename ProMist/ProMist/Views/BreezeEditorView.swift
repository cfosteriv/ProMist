import SwiftUI

struct BreezeLibraryView: View {
    @Environment(BreezeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editingPreset: BreezePreset?

    var body: some View {
        NavigationStack {
            List {
                Section("Original") {
                    ForEach(BuiltInBreeze.allCases) { breeze in
                        Label(breeze.name, systemImage: "lock.fill")
                    }
                }
                Section("My Breezes") {
                    if library.presets.isEmpty {
                        ContentUnavailableView(
                            "No Custom Breezes",
                            systemImage: "waveform.path",
                            description: Text("Create as many presets as you like. Up to three can be installed on the fan.")
                        )
                    }
                    ForEach(library.presets) { preset in
                        Button {
                            editingPreset = preset
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name)
                                Text("\(preset.cycleSeconds) seconds · \(preset.normalizedKeyframes.count) points")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { library.presets[$0] }.forEach(library.delete)
                    }
                }
            }
            .navigationTitle("Breeze Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingPreset = .fresh()
                    } label: {
                        Label("Create Breeze", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editingPreset) { preset in
                BreezeEditorView(preset: preset) {
                    library.save($0)
                    editingPreset = nil
                }
            }
        }
    }
}

struct BreezeEditorView: View {
    @Environment(BreezeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var preset: BreezePreset
    @State private var selectedSecond: Int?
    let onSave: (BreezePreset) -> Void

    init(preset: BreezePreset, onSave: @escaping (BreezePreset) -> Void) {
        _preset = State(initialValue: preset)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Breeze name", text: $preset.name)
                }

                Section("Cycle") {
                    Picker("Cycle time", selection: $preset.cycleSeconds) {
                        ForEach(BreezePreset.allowedCycleSeconds, id: \.self) {
                            Text($0 == 60 ? "1 min" : "\($0) sec").tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    BreezeWaveformEditor(
                        cycleSeconds: preset.cycleSeconds,
                        keyframes: Binding(
                            get: { preset.normalizedKeyframes },
                            set: { preset.keyframes = $0 }
                        ),
                        selectedSecond: $selectedSecond
                    )
                    .frame(height: 230)

                    HStack {
                        Text("Tap to add or select a point. Drag selected points to adjust them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let selectedSecond, selectedSecond != 0 {
                            Button("Delete", role: .destructive) {
                                preset.keyframes.removeAll { $0.second == selectedSecond }
                                self.selectedSecond = nil
                            }
                        }
                    }
                } header: {
                    Text("Power over time")
                } footer: {
                    if let message = library.validationMessage(for: preset) {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Power is limited to five calibrated levels. Adjacent points may differ by no more than two levels.")
                    }
                }
            }
            .navigationTitle("Edit Breeze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { onSave(preset) }
                        .disabled(library.validationMessage(for: preset) != nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu("Template", systemImage: "waveform") {
                        Button("Gentle Wave") { applyWaveTemplate() }
                        Button("Solid Bar") {
                            preset.keyframes = [BreezeKeyframe(second: 0, level: 3)]
                            selectedSecond = 0
                        }
                    }
                }
            }
            .onChange(of: preset.cycleSeconds) { _, duration in
                preset.keyframes.removeAll { $0.second >= duration }
                if !preset.keyframes.contains(where: { $0.second == 0 }) {
                    preset.keyframes.append(BreezeKeyframe(second: 0, level: 3))
                }
                selectedSecond = nil
            }
        }
    }

    private func applyWaveTemplate() {
        let third = preset.cycleSeconds / 3
        preset.keyframes = [
            BreezeKeyframe(second: 0, level: 3),
            BreezeKeyframe(second: third, level: 5),
            BreezeKeyframe(second: third * 2, level: 3)
        ]
        selectedSecond = nil
    }
}

private struct BreezeWaveformEditor: View {
    let cycleSeconds: Int
    @Binding var keyframes: [BreezeKeyframe]
    @Binding var selectedSecond: Int?
    @State private var draggingSecond: Int?

    private let coordinateSpaceName = "breezeWaveformPlot"

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(x: 28, y: 8, width: proxy.size.width - 36, height: proxy.size.height - 34)
            ZStack(alignment: .topLeading) {
                grid(in: plot)
                waveformArea(in: plot)
                    .fill(Color.accentColor.opacity(0.16))
                waveform(in: plot)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                ForEach(keyframes, id: \.second) { frame in
                    Circle()
                        .fill(selectedSecond == frame.second ? Color.orange : Color.accentColor)
                        .stroke(.background, lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                        .position(point(for: frame, in: plot))
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
            .contentShape(Rectangle())
            .onTapGesture { location in
                selectOrAdd(at: location, in: plot)
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpaceName))
                    .onChanged { value in
                        if draggingSecond == nil {
                            draggingSecond = nearestFrame(
                                to: value.startLocation,
                                in: plot,
                                maximumDistance: 24
                            )?.second
                            selectedSecond = draggingSecond
                        }
                        guard let sourceSecond = draggingSecond,
                              let movedSecond = move(
                                from: sourceSecond,
                                to: value.location,
                                in: plot
                              ) else { return }
                        draggingSecond = movedSecond
                    }
                    .onEnded { _ in
                        draggingSecond = nil
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Breeze power waveform")
        .accessibilityValue("\(keyframes.count) points over \(cycleSeconds) seconds")
    }

    private func grid(in plot: CGRect) -> some View {
        Canvas { context, _ in
            for level in 1...5 {
                let y = yPosition(level, in: plot)
                var path = Path()
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(path, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                context.draw(Text("\(level)").font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: 12, y: y))
            }
            for quarter in 0...4 {
                let x = plot.minX + plot.width * CGFloat(quarter) / 4
                var path = Path()
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(path, with: .color(.secondary.opacity(0.14)), lineWidth: 1)
            }
        }
    }

    private func waveform(in plot: CGRect) -> Path {
        var path = Path()
        let frames = keyframes.sorted { $0.second < $1.second }
        guard let first = frames.first else { return path }

        var previous = point(for: first, in: plot)
        path.move(to: previous)
        for frame in frames.dropFirst() {
            let next = point(for: frame, in: plot)
            addSmoothSegment(from: previous, to: next, to: &path)
            previous = next
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: previous.y))
        return path
    }

    private func waveformArea(in plot: CGRect) -> Path {
        var path = waveform(in: plot)
        guard !keyframes.isEmpty else { return path }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    private func addSmoothSegment(from start: CGPoint, to end: CGPoint, to path: inout Path) {
        let controlOffset = (end.x - start.x) * 0.42
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + controlOffset, y: start.y),
            control2: CGPoint(x: end.x - controlOffset, y: end.y)
        )
    }

    private func point(for frame: BreezeKeyframe, in plot: CGRect) -> CGPoint {
        CGPoint(
            x: plot.minX + CGFloat(frame.second) / CGFloat(cycleSeconds) * plot.width,
            y: yPosition(frame.level, in: plot)
        )
    }

    private func yPosition(_ level: Int, in plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(level - 1) / 4 * plot.height
    }

    private func selectOrAdd(at location: CGPoint, in plot: CGRect) {
        guard plot.insetBy(dx: -10, dy: -10).contains(location) else { return }
        let second = min(cycleSeconds - 1, max(0,
            Int(((location.x - plot.minX) / plot.width * CGFloat(cycleSeconds)).rounded())
        ))
        if let existing = keyframes.min(by: {
            abs($0.second - second) < abs($1.second - second)
        }), abs(existing.second - second) <= 1 {
            selectedSecond = existing.second
            return
        }
        guard keyframes.count < BreezePreset.maximumKeyframes else { return }
        let requested = level(at: location, in: plot)
        let safe = constrainedLevel(requested, at: second, excluding: nil)
        keyframes.append(BreezeKeyframe(second: second, level: safe))
        keyframes.sort { $0.second < $1.second }
        selectedSecond = second
    }

    private func nearestFrame(
        to location: CGPoint,
        in plot: CGRect,
        maximumDistance: CGFloat
    ) -> BreezeKeyframe? {
        keyframes.min { lhs, rhs in
            squaredDistance(from: point(for: lhs, in: plot), to: location)
                < squaredDistance(from: point(for: rhs, in: plot), to: location)
        }.flatMap { frame in
            squaredDistance(from: point(for: frame, in: plot), to: location)
                <= maximumDistance * maximumDistance ? frame : nil
        }
    }

    private func squaredDistance(from point: CGPoint, to location: CGPoint) -> CGFloat {
        let dx = point.x - location.x
        let dy = point.y - location.y
        return dx * dx + dy * dy
    }

    @discardableResult
    private func move(
        from sourceSecond: Int,
        to location: CGPoint,
        in plot: CGRect
    ) -> Int? {
        guard let index = keyframes.firstIndex(where: { $0.second == sourceSecond }) else {
            return nil
        }
        let newSecond = sourceSecond == 0 ? 0 : min(cycleSeconds - 1, max(1,
            Int(((location.x - plot.minX) / plot.width * CGFloat(cycleSeconds)).rounded())
        ))
        guard !keyframes.contains(where: { $0.second == newSecond && $0.second != sourceSecond }) else {
            return sourceSecond
        }
        let requested = level(at: location, in: plot)
        keyframes[index] = BreezeKeyframe(
            second: newSecond,
            level: constrainedLevel(requested, at: newSecond, excluding: sourceSecond)
        )
        keyframes.sort { $0.second < $1.second }
        selectedSecond = newSecond
        return newSecond
    }

    private func level(at location: CGPoint, in plot: CGRect) -> Int {
        min(5, max(1, Int((1 + (plot.maxY - location.y) / plot.height * 4).rounded())))
    }

    private func constrainedLevel(_ requested: Int, at second: Int, excluding: Int?) -> Int {
        let others = keyframes.filter { $0.second != excluding }.sorted { $0.second < $1.second }
        guard !others.isEmpty else { return min(5, max(1, requested)) }
        let previous = others.last(where: { $0.second < second }) ?? others.last!
        let next = others.first(where: { $0.second > second }) ?? others.first!
        let lower = max(1, previous.level - 2, next.level - 2)
        let upper = min(5, previous.level + 2, next.level + 2)
        return min(upper, max(lower, requested))
    }
}
