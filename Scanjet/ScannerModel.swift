import AppKit
import Observation
import os
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScannerModel {
    enum ScanKind: Sendable { case preview, final }

    enum CanvasMode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case result = "Scan"
        var id: String { rawValue }
    }

    enum Activity: Equatable {
        case disconnected
        case connecting
        case idle
        case warmingUp(ScanKind)
        case reading(ScanKind, done: Int, total: Int)
        /// Cancel requested; the backend finishes lamp warm-up and calibration before it notices.
        case cancelling(ScanKind)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
    }

    /// A group header followed by the options that belong to it, in backend order.
    struct Section: Identifiable {
        let title: String
        let options: [ScanOption]
        var id: String { title }
    }

    struct Preset: Identifiable {
        let name: String
        let settings: [(option: String, value: OptionValue)]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Document", settings: [
            ("source", .string("Flatbed")), ("mode", .string("Color")), ("resolution", .int(300)), ("depth", .int(8)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)), ("opt_realdepth", .bool(false)),
        ]),
        Preset(name: "Photo", settings: [
            ("source", .string("Flatbed")), ("mode", .string("Color")), ("resolution", .int(600)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)), ("opt_realdepth", .bool(false)),
        ]),
        Preset(name: "Negative film", settings: [
            ("source", .string("Negative")), ("mode", .string("Color")), ("resolution", .int(2400)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)), ("opt_realdepth", .bool(false)),
        ]),
        Preset(name: "Slide", settings: [
            ("source", .string("Slide")), ("mode", .string("Color")), ("resolution", .int(2400)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)), ("opt_realdepth", .bool(false)),
        ]),
        // What the sensor saw: no gamma curve, no white-shading correction, true 16-bit samples.
        Preset(name: "Raw sensor", settings: [
            ("mode", .string("Color")), ("depth", .int(16)),
            ("opt_nogamma", .bool(true)), ("opt_nowshading", .bool(true)), ("opt_realdepth", .bool(true)),
        ]),
    ]

    private(set) var activity: Activity = .disconnected
    private(set) var deviceName = ""
    private(set) var options: [ScanOption] = []
    private(set) var errorMessage: String?
    private(set) var log: [LogEntry] = []

    /// Low-resolution scan of the whole bed, used to pick the scan area.
    private(set) var previewImage: CGImage?
    /// The last full scan and what the canvas shows for it (possibly inverted).
    private(set) var result: ScanFrame?
    private(set) var resultImage: CGImage?
    /// Per-channel levels; switched on automatically for film sources, see `scan()`.
    var balanceResult = false {
        didSet { refreshResultImage() }
    }
    var invertResult = false {
        didSet { refreshResultImage() }
    }
    var showAdvanced = false
    /// Which image the canvas shows; flips automatically when a preview or scan completes.
    var canvasMode: CanvasMode = .preview

    private let scanner = SaneScanner()
    private let logger = Logger(subsystem: "nainajnahO.Scanjet", category: "scanner")
    private var sensorTask: Task<Void, Never>?

    // MARK: Derived state

    var isConnected: Bool { activity != .disconnected && activity != .connecting }
    var isScanning: Bool {
        switch activity {
        case .warmingUp, .reading, .cancelling: true
        default: false
        }
    }
    var canScan: Bool { activity == .idle }
    var canCancel: Bool {
        switch activity {
        case .warmingUp, .reading: true
        default: false
        }
    }

    /// Selection being dragged on the preview, in millimetres. Shown in place of the backend's
    /// values until `setArea` has committed it, so the numbers follow the mouse.
    var draggingArea: CGRect?

    /// Scan area in whole millimetres: the drag in progress, else what the backend has.
    var area: CGRect {
        if let draggingArea { return Self.wholeMillimetres(draggingArea) }
        let left = intValue("tl-x"), top = intValue("tl-y")
        let right = intValue("br-x"), bottom = intValue("br-y")
        return CGRect(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
    }

    private static func wholeMillimetres(_ rect: CGRect) -> CGRect {
        let left = rect.minX.rounded(), top = rect.minY.rounded()
        return CGRect(x: left, y: top, width: rect.maxX.rounded() - left, height: rect.maxY.rounded() - top)
    }

    /// Physical size of the glass, from the geometry options' upper limits.
    var bedSize: CGSize {
        CGSize(width: CGFloat(maxValue("br-x")), height: CGFloat(maxValue("br-y")))
    }

    var sections: [Section] {
        var sections: [Section] = []
        var title = "General"
        var pending: [ScanOption] = []
        func flush() {
            let visible = pending.filter { $0.isActive && (showAdvanced || !$0.isAdvanced) }
            if !visible.isEmpty { sections.append(Section(title: title, options: visible)) }
            pending = []
        }
        let live: [String: Int] = draggingArea.map { _ in
            let area = self.area
            return ["tl-x": Int(area.minX), "tl-y": Int(area.minY), "br-x": Int(area.maxX), "br-y": Int(area.maxY)]
        } ?? [:]
        for var option in options {
            if option.kind == .group {
                flush()
                title = option.title
            } else if option.value != nil || option.kind == .button {
                if let value = live[option.name] { option.value = .int(value) }
                pending.append(option)
            }
        }
        flush()
        return sections
    }

    // MARK: Connection

    func connect() async {
        activity = .connecting
        errorMessage = nil
        do {
            let device = try await scanner.connect()
            deviceName = "\(device.vendor) \(device.model)"
            options = try await scanner.options()
            activity = .idle
            note("Connected to \(deviceName) (\(device.name))")
            startWatchingButtons()
        } catch {
            activity = .disconnected
            fail("Could not open scanner", error)
        }
    }

    // MARK: Options

    func set(_ name: String, to value: OptionValue) {
        Task {
            do {
                try await scanner.set(name, to: value)
                options = try await scanner.options()
                note("\(name) = \(describe(value))")
            } catch {
                fail("Could not set \(name)", error)
            }
        }
    }

    func press(_ name: String) {
        Task {
            do {
                try await scanner.press(name)
                options = try await scanner.options()
                note("Pressed \(name)")
            } catch {
                fail("Could not press \(name)", error)
            }
        }
    }

    func apply(_ preset: Preset) {
        Task {
            do {
                for setting in preset.settings {
                    try await scanner.set(setting.option, to: setting.value)
                }
                options = try await scanner.options()
                note("Applied preset “\(preset.name)”")
            } catch {
                fail("Could not apply preset “\(preset.name)”", error)
            }
        }
    }

    func setArea(_ rect: CGRect) {
        let rect = Self.wholeMillimetres(rect)
        draggingArea = rect
        Task {
            defer { if draggingArea == rect { draggingArea = nil } }   // Unless a new drag has begun.
            do {
                // Set the origin first so the far edge never has to be below it.
                try await scanner.set("tl-x", to: .int(Int(rect.minX)))
                try await scanner.set("tl-y", to: .int(Int(rect.minY)))
                try await scanner.set("br-x", to: .int(Int(rect.maxX)))
                try await scanner.set("br-y", to: .int(Int(rect.maxY)))
                options = try await scanner.options()
                note("Scan area \(Int(rect.minX)),\(Int(rect.minY)) – \(Int(rect.maxX)),\(Int(rect.maxY)) mm")
            } catch {
                fail("Could not set scan area", error)
            }
        }
    }

    func selectWholeBed() {
        setArea(CGRect(origin: .zero, size: bedSize))
    }

    // MARK: Scanning

    /// Whole bed at the lowest resolution, 8-bit, then every option put back as it was.
    func preview() {
        guard canScan else { return }
        Task {
            let saved = options.filter { ["resolution", "depth", "tl-x", "tl-y", "br-x", "br-y"].contains($0.name) }
            do {
                let lowest = options.first { $0.name == "resolution" }.flatMap { option -> Int? in
                    if case .intList(let values) = option.constraint { return values.min() }
                    return nil
                } ?? 50
                try await scanner.set("resolution", to: .int(lowest))
                try await scanner.set("depth", to: .int(8))
                try await scanner.set("tl-x", to: .int(0))
                try await scanner.set("tl-y", to: .int(0))
                try await scanner.set("br-x", to: .int(Int(bedSize.width)))
                try await scanner.set("br-y", to: .int(Int(bedSize.height)))
                let frame = try await run(.preview)
                previewImage = frame.cgImage
                canvasMode = .preview
            } catch is CancellationError {
                note("Preview cancelled")
            } catch {
                fail("Preview failed", error)
            }
            await restore(saved)
            activity = .idle
        }
    }

    func scan() {
        guard canScan else { return }
        Task {
            do {
                let frame = try await run(.final)
                result = frame
                balanceResult = isFilmSource   // Its didSet renders the result.
                canvasMode = .result
            } catch is CancellationError {
                note("Scan cancelled")
            } catch {
                fail("Scan failed", error)
            }
            activity = .idle
        }
    }

    func cancel() {
        let kind: ScanKind
        switch activity {
        case .warmingUp(let current), .reading(let current, _, _): kind = current
        default: return
        }
        scanner.cancel()
        activity = .cancelling(kind)
    }

    private func run(_ kind: ScanKind) async throws -> ScanFrame {
        scanner.clearCancel()
        activity = .warmingUp(kind)
        errorMessage = nil
        let started = Date()
        note(kind == .preview ? "Preview started" : "Scan started: \(settingsSummary)")
        let frame = try await scanner.scan { done, total in
            Task { @MainActor in
                guard self.canCancel else { return }   // Don't overwrite "Cancelling…".
                self.activity = .reading(kind, done: done, total: total)
            }
        }
        let seconds = Date().timeIntervalSince(started)
        note(String(format: "%@ finished: %d×%d px, %d-bit, %d channel(s), %.1f MB in %.0f s",
                    kind == .preview ? "Preview" : "Scan", frame.width, frame.height, frame.depth,
                    frame.channels, Double(frame.pixels.count) / 1_048_576, seconds))
        if frame.height < frame.announcedHeight {
            note("Scanner stopped early: delivered \(frame.height) of \(frame.announcedHeight) lines")
        }
        return frame
    }

    private func restore(_ saved: [ScanOption]) async {
        do {
            for option in saved {
                if let value = option.value { try await scanner.set(option.name, to: value) }
            }
            options = try await scanner.options()
        } catch {
            fail("Could not restore settings after preview", error)
        }
    }

    /// True when the current source option is the transparency adapter (Negative or Slide).
    private var isFilmSource: Bool {
        if case .string(let source)? = options.first(where: { $0.name == "source" })?.value {
            return source != "Flatbed"
        }
        return false
    }

    /// The scan with the toolbar toggles applied; what the canvas shows and Save writes.
    private var processedResult: ScanFrame? {
        guard var frame = result else { return nil }
        if invertResult { frame = frame.inverted() }
        if balanceResult { frame = frame.balanced() }
        return frame
    }

    private func refreshResultImage() {
        resultImage = processedResult?.cgImage
    }

    // MARK: Saving

    func save() {
        guard let result = processedResult else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff, .jpeg]
        panel.nameFieldStringValue = "Scan " + Date().formatted(.dateTime.year().month().day().hour().minute()) + ".png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        do {
            try result.write(to: url, as: type)
            note("Saved \(url.lastPathComponent)")
        } catch {
            fail("Could not save", error)
        }
    }

    // MARK: Front-panel buttons

    /// Polls the scanner's buttons while idle; any press starts a scan, like the original software.
    private func startWatchingButtons() {
        sensorTask?.cancel()
        sensorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard canScan else { continue }
                guard let states = try? await scanner.sensors(),
                      let pressed = states.first(where: { $0.value })?.key else { continue }
                note("Scanner button “\(pressed)” pressed")
                scan()
            }
        }
    }

    // MARK: Helpers

    private func intValue(_ name: String) -> Int {
        if case .int(let value)? = options.first(where: { $0.name == name })?.value { return value }
        return 0
    }

    private func maxValue(_ name: String) -> Int {
        if case .range(_, let max, _)? = options.first(where: { $0.name == name })?.constraint { return max }
        return 0
    }

    private var settingsSummary: String {
        ["source", "mode", "resolution", "depth"]
            .compactMap { name in options.first { $0.name == name }?.value.map(describe) }
            .joined(separator: ", ")
    }

    private func describe(_ value: OptionValue) -> String {
        switch value {
        case .bool(let flag): flag ? "on" : "off"
        case .int(let number): String(number)
        case .fixed(let number): number.formatted()
        case .string(let text): text
        }
    }

    private func note(_ message: String) {
        log.append(LogEntry(message: message))
        logger.notice("\(message, privacy: .public)")
    }

    private func fail(_ context: String, _ error: Error) {
        errorMessage = "\(context): \(error.localizedDescription)"
        note("⚠️ \(errorMessage ?? context)")
    }
}
