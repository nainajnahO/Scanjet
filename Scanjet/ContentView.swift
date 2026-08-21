import SwiftUI

struct ContentView: View {
    @Environment(ScannerModel.self) private var model
    @State private var showLog = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            // Toolbar, inspector and status bar belong to the detail column. Attaching them
            // to the split view itself spans them across the sidebar and loses the
            // full-height floating sidebar treatment.
            ImageCanvas(mode: model.canvasMode)
                .safeAreaInset(edge: .bottom) { StatusBar() }
                .navigationTitle(model.deviceName.isEmpty ? "Scanjet" : model.deviceName)
                .toolbar {
                    ToolbarItemGroup(placement: .principal) {
                        Picker("Show", selection: $model.canvasMode) {
                            ForEach(ScannerModel.CanvasMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if model.isScanning {
                            Button("Cancel", systemImage: "xmark.circle") { model.cancel() }
                                .disabled(!model.canCancel)
                        } else {
                            Button("Preview", systemImage: "eye") { model.preview() }
                                .disabled(!model.canScan)
                            Button("Scan", systemImage: "scanner") { model.scan() }
                                .disabled(!model.canScan)
                        }
                        Toggle("Invert", systemImage: "circle.lefthalf.filled", isOn: $model.invertResult)
                            .disabled(model.result == nil)
                        Toggle("Balance", systemImage: "slider.horizontal.3", isOn: $model.balanceResult)
                            .disabled(model.result == nil)
                        Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                            .disabled(model.result == nil)
                        Toggle("Log", systemImage: "list.bullet.rectangle", isOn: $showLog)
                    }
                }
                // The canvas doesn't scroll under the toolbar, so the window would otherwise
                // draw a hard separator line beneath it.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .inspector(isPresented: $showLog) {
                    LogView()
                        .inspectorColumnWidth(min: 260, ideal: 340)
                }
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Environment(ScannerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if model.isConnected {
                    Menu("Apply preset…") {
                        ForEach(ScannerModel.presets) { preset in
                            Button(preset.name) { model.apply(preset) }
                        }
                    }
                    Button("Use whole bed as scan area") { model.selectWholeBed() }
                    Toggle("Show advanced options", isOn: $model.showAdvanced)
                } else {
                    LabeledContent("Scanner") {
                        Text(model.activity == .connecting ? "Connecting…" : "Not connected")
                            .foregroundStyle(.secondary)
                    }
                    Button("Reconnect") { Task { await model.connect() } }
                        .disabled(model.activity == .connecting)
                }
            }
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.options) { option in
                        OptionRow(option: option)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isScanning)
    }
}

/// Picks a native control from the option's SANE type and constraint.
private struct OptionRow: View {
    @Environment(ScannerModel.self) private var model
    let option: ScanOption

    var body: some View {
        Group {
            switch (option.kind, option.constraint, option.value) {
            case (.bool, _, .bool(let flag)) where !option.isSettable:
                LabeledContent(option.title) {
                    Image(systemName: flag ? "circle.fill" : "circle")
                        .foregroundStyle(flag ? Color.accentColor : Color.secondary)
                }
            case (_, _, let value?) where !option.isSettable:
                LabeledContent(option.title) {
                    Text(describe(value)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            case (.bool, _, .bool(let flag)):
                Toggle(option.title, isOn: binding(flag) { .bool($0) })
            case (.string, .stringList(let choices), .string(let current)):
                Picker(option.title, selection: binding(current) { .string($0) }) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
            case (.int, .intList(let choices), .int(let current)):
                Picker(option.title, selection: binding(current) { .int($0) }) {
                    ForEach(choices, id: \.self) { Text("\($0) \(option.unit)").tag($0) }
                }
            case (.int, .range(let low, let high, let step), .int(let current)):
                LabeledContent(option.title) {
                    HStack {
                        TextField(option.title, value: binding(current) { .int($0) }, format: .number)
                            .labelsHidden()
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                        Stepper(option.unit, value: binding(current) { .int($0) }, in: low...high, step: max(step, 1))
                    }
                }
            case (.int, _, .int(let current)):
                LabeledContent(option.title) {
                    TextField(option.title, value: binding(current) { .int($0) }, format: .number)
                        .labelsHidden()
                        .frame(width: 80)
                }
            case (.fixed, _, .fixed(let current)):
                LabeledContent(option.title) {
                    TextField(option.title, value: binding(current) { .fixed($0) }, format: .number)
                        .labelsHidden()
                        .frame(width: 80)
                }
            case (.button, _, _):
                Button(option.title) { model.press(option.name) }
            default:
                LabeledContent(option.title) {
                    Text(option.value.map(describe) ?? "–").foregroundStyle(.secondary)
                }
            }
        }
        .help(option.detail)
    }

    private func describe(_ value: OptionValue) -> String {
        switch value {
        case .bool(let flag): flag ? "Yes" : "No"
        case .int(let number): "\(number) \(option.unit)".trimmingCharacters(in: .whitespaces)
        case .fixed(let number): number.formatted()
        case .string(let text): text
        }
    }

    private func binding<T>(_ current: T, _ wrap: @escaping (T) -> OptionValue) -> Binding<T> {
        Binding(get: { current }, set: { model.set(option.name, to: wrap($0)) })
    }
}

// MARK: - Canvas

private struct ImageCanvas: View {
    @Environment(ScannerModel.self) private var model
    let mode: ScannerModel.CanvasMode
    @State private var dragRect: CGRect?

    var body: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    let frame = fittedFrame(for: image, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                        if mode == .preview {
                            selectionOverlay(in: frame)
                        }
                    }
                    // Top-leading so the offsets above are measured from the canvas origin,
                    // the same space the drag gesture reports in.
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(mode == .preview ? selectionGesture(in: frame) : nil)
                }
            } else {
                // Outside the GeometryReader so it fills the canvas and centres itself.
                ContentUnavailableView {
                    Label(mode == .preview ? "No preview yet" : "No scan yet", systemImage: "scanner")
                } description: {
                    Text(mode == .preview
                         ? "Preview scans the whole bed at low resolution so you can drag out the area to scan."
                         : "Scan uses the settings in the sidebar and the selected area.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.05))
    }

    private var image: CGImage? {
        mode == .preview ? model.previewImage : model.resultImage
    }

    /// Where the image lands when scaled to fit, letterboxed and centred.
    private func fittedFrame(for image: CGImage, in size: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let available = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    // The preview always covers the whole bed, so view points map linearly to millimetres.
    private func pointsPerMM(in frame: CGRect) -> CGFloat {
        frame.width / max(model.bedSize.width, 1)
    }

    private func selectionOverlay(in frame: CGRect) -> some View {
        let scale = pointsPerMM(in: frame)
        let area = model.area
        let rect = dragRect ?? CGRect(x: frame.minX + area.minX * scale, y: frame.minY + area.minY * scale,
                                      width: area.width * scale, height: area.height * scale)
        return Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.12))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    private func selectionGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                let start = clamp(drag.startLocation, to: frame)
                let end = clamp(drag.location, to: frame)
                let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                dragRect = rect
                model.draggingArea = millimetres(of: rect, in: frame)
            }
            .onEnded { _ in
                guard let dragRect else { return }
                self.dragRect = nil
                model.setArea(millimetres(of: dragRect, in: frame))
            }
    }

    private func millimetres(of rect: CGRect, in frame: CGRect) -> CGRect {
        let scale = pointsPerMM(in: frame)
        return CGRect(x: (rect.minX - frame.minX) / scale, y: (rect.minY - frame.minY) / scale,
                      width: rect.width / scale, height: rect.height / scale)
    }

    private func clamp(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
    }
}

// MARK: - Status bar & log

private struct StatusBar: View {
    @Environment(ScannerModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.activity {
            case .disconnected:
                Label("Not connected", systemImage: "scanner")
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .idle:
                Label(areaSummary, systemImage: "rectangle.dashed")
            case .warmingUp(let kind):
                ProgressView().controlSize(.small)
                Text(kind == .preview ? "Preview: warming up lamp…" : "Scan: warming up lamp…")
            case .reading(let kind, let done, let total):
                if total > 0, done >= total {
                    // Every line is in; the backend's final read only returns once it has
                    // stopped the scanner, and it reports nothing during that.
                    ProgressView().controlSize(.small)
                    Text("\(kind == .preview ? "Preview" : "Scan"): all \(total) lines received, waiting for scanner…")
                } else if total > 0 {
                    ProgressView(value: Double(done), total: Double(total)).frame(width: 180)
                    Text("\(kind == .preview ? "Preview" : "Scan"): line \(done) of \(total)")
                } else {
                    ProgressView().controlSize(.small)
                    Text("\(kind == .preview ? "Preview" : "Scan"): line \(done)")
                }
            case .cancelling(let kind):
                ProgressView().controlSize(.small)
                Text(kind == .preview ? "Cancelling preview…" : "Cancelling scan…")
            }
            Spacer()
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var areaSummary: String {
        let area = model.area
        return "Area \(Int(area.minX)),\(Int(area.minY)) – \(Int(area.maxX)),\(Int(area.maxY)) mm"
    }
}

private struct LogView: View {
    @Environment(ScannerModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(model.log) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.time, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
            .padding(10)
        }
        .defaultScrollAnchor(.bottom)
    }
}
