import AppKit
import Observation
import os
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScannerModel {
    enum ScanKind: String, Sendable {
        case preview = "Preview"
        case final = "Scan"
    }

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

    /// Film laid on the glass and lit from above, scanned with the Flatbed source. The backend's
    /// Negative/Slide sources are hard-cropped to the lid backlight window (45 mm wide on the
    /// G3010), so freehand film has to go through Flatbed and be processed here instead.
    enum FlatbedFilm: String, CaseIterable, Identifiable {
        case none = "None"
        case negative = "Negative"
        case slide = "Slide"
        var id: String { rawValue }
    }

    struct Preset: Identifiable {
        let name: String
        let settings: [(option: String, value: OptionValue)]
        var film = FlatbedFilm.none
        var id: String { name }
    }

    /// Option names are hp3900's; a setting whose option the connected backend lacks is skipped.
    static let presets: [Preset] = [
        Preset(name: "Document", settings: [
            ("source", .string("Flatbed")), ("mode", .string("Color")), ("resolution", .int(300)), ("depth", .int(8)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)),
        ]),
        Preset(name: "Photo", settings: [
            ("source", .string("Flatbed")), ("mode", .string("Color")), ("resolution", .int(600)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)),
        ]),
        Preset(name: "Negative film", settings: [
            ("source", .string("Negative")), ("mode", .string("Color")), ("resolution", .int(2400)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)),
        ]),
        Preset(name: "Slide", settings: [
            ("source", .string("Slide")), ("mode", .string("Color")), ("resolution", .int(2400)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)),
        ]),
        Preset(name: "Negative on flatbed", settings: [
            ("source", .string("Flatbed")), ("mode", .string("Color")), ("resolution", .int(2400)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)),
        ], film: .negative),
        Preset(name: "Slide on flatbed", settings: [
            ("source", .string("Flatbed")), ("mode", .string("Color")), ("resolution", .int(2400)), ("depth", .int(16)),
            ("opt_nogamma", .bool(false)), ("opt_nowshading", .bool(false)),
        ], film: .slide),
        // What the sensor saw: no gamma curve, no white-shading correction, 16-bit samples.
        Preset(name: "Raw sensor", settings: [
            ("mode", .string("Color")), ("depth", .int(16)),
            ("opt_nogamma", .bool(true)), ("opt_nowshading", .bool(true)),
        ]),
    ]

    private(set) var activity: Activity = .disconnected
    private(set) var deviceName = ""
    private(set) var options: [ScanOption] = [] {
        didSet {
            // Switching between flatbed and film adapter changes the bed; the preview no longer
            // shows what a drag would select.
            if previewImage != nil, bedSize != previewBedSize {
                previewImage = nil
                note("Preview discarded: the scan bed changed size")
            }
        }
    }
    private(set) var errorMessage: String?
    private(set) var log: [LogEntry] = []

    /// Low-resolution scan of the whole bed, used to pick the scan area.
    private(set) var previewImage: CGImage?
    private var previewBedSize = CGSize.zero
    /// The last full scan; `resultImage` is a display-sized rendering of it with the toggles applied.
    private(set) var result: ScanFrame? {
        didSet { scheduleRender() }
    }
    private(set) var resultImage: CGImage?
    /// `result` with the toggles applied, ready for Save; nil while that is being computed.
    private var processedResult: ScanFrame?
    private(set) var isProcessing = false
    /// Per-channel levels; switched on automatically for film sources, see `scan()`.
    var balanceResult = false {
        didSet { scheduleRender() }
    }
    var invertResult = false {
        didSet { scheduleRender() }
    }
    var showAdvanced = false
    /// What a Flatbed scan is of; decides the Invert/Balance defaults after each scan.
    var flatbedFilm = FlatbedFilm.none
    /// Which image the canvas shows; flips automatically when a preview or scan completes.
    var canvasMode: CanvasMode = .preview

    private let scanner = SaneScanner()
    private let logger = Logger(subsystem: "nainajnahO.Scanjet", category: "scanner")
    private var sensorTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var renderScheduled = false

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
    var canSave: Bool { processedResult != nil && !isProcessing }

    /// Selection being dragged on the preview, in millimetres. Shown in place of the backend's
    /// values until `setArea` has committed it, so the numbers follow the mouse.
    var draggingArea: CGRect?

    /// Scan area in whole millimetres: the drag in progress, else what the backend has.
    var area: CGRect {
        if let draggingArea { return Self.wholeMillimetres(draggingArea) }
        let left = number("tl-x"), top = number("tl-y")
        let right = number("br-x"), bottom = number("br-y")
        return CGRect(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
    }

    private static func wholeMillimetres(_ rect: CGRect) -> CGRect {
        let left = rect.minX.rounded(), top = rect.minY.rounded()
        return CGRect(x: left, y: top, width: rect.maxX.rounded() - left, height: rect.maxY.rounded() - top)
    }

    /// Physical size of the glass, from the geometry options' upper limits.
    var bedSize: CGSize {
        CGSize(width: maximum("br-x"), height: maximum("br-y"))
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
        let live = draggingArea.map { _ in Dictionary(uniqueKeysWithValues: geometrySettings(for: area).map { ($0.name, $0.value) }) } ?? [:]
        for var option in options {
            if option.kind == .group {
                flush()
                title = option.title
            } else if option.value != nil || option.kind == .button {
                if let value = live[option.name] { option.value = value }
                pending.append(option)
            }
        }
        flush()
        return sections
    }

    // MARK: Connection

    func connect() async {
        sensorTask?.cancel()
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

    /// Stops any scan and releases the scanner. Called when the app quits so the backend gets
    /// to park the carriage and arm the lamp timer instead of being killed mid-read.
    func shutdown() async {
        sensorTask?.cancel()
        cancel()
        await scanner.disconnect()
        activity = .disconnected
    }

    /// The backend lost the device; behave as if it was never opened until Reconnect.
    private func lostScanner() async {
        sensorTask?.cancel()
        await scanner.disconnect()
        activity = .disconnected
        note("Lost contact with the scanner")
    }

    // MARK: Options

    func set(_ name: String, to value: OptionValue) {
        Task {
            do {
                try await scanner.set(name, to: value)
                note("\(name) = \(describe(value))")
            } catch {
                fail("Could not set \(name)", error)
            }
            await reloadOptions()
        }
    }

    func press(_ name: String) {
        Task {
            do {
                try await scanner.press(name)
                note("Pressed \(name)")
            } catch {
                fail("Could not press \(name)", error)
            }
            await reloadOptions()
        }
    }

    func apply(_ preset: Preset) {
        let available = Set(options.map(\.name))
        flatbedFilm = preset.film
        Task {
            do {
                for setting in preset.settings where available.contains(setting.option) {
                    try await scanner.set(setting.option, to: setting.value)
                }
                note("Applied preset “\(preset.name)”")
            } catch {
                fail("Could not apply preset “\(preset.name)”", error)
            }
            await reloadOptions()   // Even after a failure: some settings went through.
        }
    }

    func setArea(_ rect: CGRect) {
        let rect = Self.wholeMillimetres(rect)
        draggingArea = rect
        let settings = geometrySettings(for: rect)
        Task {
            defer { if draggingArea == rect { draggingArea = nil } }   // Unless a new drag has begun.
            do {
                for (name, value) in settings { try await scanner.set(name, to: value) }
                note("Scan area \(Int(rect.minX)),\(Int(rect.minY)) – \(Int(rect.maxX)),\(Int(rect.maxY)) mm")
            } catch {
                fail("Could not set scan area", error)
            }
            await reloadOptions()
        }
    }

    func selectWholeBed() {
        setArea(CGRect(origin: .zero, size: bedSize))
    }

    private func reloadOptions() async {
        do {
            options = try await scanner.options()
        } catch {
            fail("Could not read the scanner's options", error)
        }
    }

    // MARK: Scanning

    /// Whole bed at the lowest resolution, 8-bit, then every option put back as it was.
    func preview() {
        guard begin(.preview) else { return }
        Task {
            var saved: [ScanOption] = []
            do {
                // Read back from the backend rather than `options`, which can lag a set() that
                // is still queued on the scanner; restoring from a stale copy would undo it.
                let current = try await scanner.options()
                let overrides = previewOverrides(given: current)
                saved = current.filter { option in overrides.contains { $0.name == option.name } }
                for (name, value) in overrides { try await scanner.set(name, to: value) }
                let frame = try await run(.preview)
                previewBedSize = bedSize
                previewImage = frame.cgImage
                canvasMode = .preview
            } catch is CancellationError {
                note("Preview cancelled")
            } catch {
                await failScan("Preview failed", error)
            }
            if !saved.isEmpty, activity != .disconnected { await restore(saved) }
            finish()
        }
    }

    func scan() {
        guard begin(.final) else { return }
        Task {
            do {
                let frame = try await run(.final)
                // The assignments render once: the didSets coalesce into one pass.
                switch (isFilmSource, flatbedFilm) {
                case (true, _):
                    balanceResult = true   // The backend already inverted a negative.
                case (false, .negative):
                    invertResult = true
                    balanceResult = true
                case (false, .slide):
                    invertResult = false
                    balanceResult = true
                case (false, .none):
                    balanceResult = false
                }
                result = frame
                canvasMode = .result
            } catch is CancellationError {
                note("Scan cancelled")
            } catch {
                await failScan("Scan failed", error)
            }
            finish()
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

    /// Claims the scanner synchronously, so nothing else can start a scan while the preview is
    /// still changing options on the actor, and Cancel is honoured from this point on.
    private func begin(_ kind: ScanKind) -> Bool {
        guard canScan else { return false }
        scanner.clearCancel()
        activity = .warmingUp(kind)
        errorMessage = nil
        return true
    }

    private func finish() {
        if activity != .disconnected { activity = .idle }
    }

    private func run(_ kind: ScanKind) async throws -> ScanFrame {
        if case .cancelling = activity { throw CancellationError() }   // Cancelled during setup.
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
                    kind.rawValue, frame.width, frame.height, frame.depth,
                    frame.channels, Double(frame.pixels.count) / 1_048_576, seconds))
        if frame.height < frame.announcedHeight {
            note("Scanner stopped early: delivered \(frame.height) of \(frame.announcedHeight) lines")
        }
        return frame
    }

    private func failScan(_ context: String, _ error: Error) async {
        fail(context, error)
        if let sane = error as? SaneError, sane.isDeviceLost { await lostScanner() }
    }

    /// Lowest resolution, 8-bit, whole bed — for the options this backend has.
    private func previewOverrides(given current: [ScanOption]) -> [(name: String, value: OptionValue)] {
        let lowest = current.first { $0.name == "resolution" }.flatMap { option -> Int? in
            if case .intList(let values) = option.constraint { return values.min() }
            return nil
        } ?? 50
        let bed = CGRect(origin: .zero, size: bedSize)
        let overrides: [(name: String, value: OptionValue)] =
            [(name: "resolution", value: .int(lowest)), (name: "depth", value: .int(8))] + geometrySettings(for: bed)
        return overrides.filter { override in current.contains { $0.name == override.name } }
    }

    private func restore(_ saved: [ScanOption]) async {
        do {
            for option in saved {
                if let value = option.value { try await scanner.set(option.name, to: value) }
            }
        } catch {
            fail("Could not restore settings after preview", error)
        }
        await reloadOptions()
    }

    /// True when the current source option is the transparency adapter (Negative or Slide).
    private var isFilmSource: Bool {
        if case .string(let source)? = options.first(where: { $0.name == "source" })?.value {
            return ["Negative", "Slide"].contains(source)
        }
        return false
    }

    // MARK: Rendering

    /// Runs the toggles over `result` once per main-actor turn, off the main actor: a full-bed
    /// 16-bit frame takes seconds to balance and would otherwise freeze the window.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            renderScheduled = false
            render()
        }
    }

    private func render() {
        renderTask?.cancel()
        guard let result else {
            processedResult = nil
            resultImage = nil
            isProcessing = false
            return
        }
        let invert = invertResult, balance = balanceResult
        isProcessing = true
        renderTask = Task {
            let frame = await Task.detached(priority: .userInitiated) {
                result.processed(invert: invert, balance: balance)
            }.value
            let image = await Task.detached(priority: .userInitiated) { frame.displayImage() }.value
            guard !Task.isCancelled else { return }
            processedResult = frame
            resultImage = image
            isProcessing = false
        }
    }

    // MARK: Saving

    func save() {
        guard let processedResult else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff, .jpeg]
        // No colon: macOS shows it as "/" in file names.
        let stamp = Date().formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
            timeZone: .current, calendar: .current))
        panel.nameFieldStringValue = "Scan \(stamp).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        do {
            try processedResult.write(to: url, as: type)
            note("Saved \(url.lastPathComponent)")
        } catch {
            fail("Could not save", error)
        }
    }

    // MARK: Front-panel buttons

    /// Polls the scanner's buttons while idle; a press starts a scan, like the original software.
    /// Edge-triggered: a button that reads as held (hp3900 reports every button pressed once the
    /// USB link is gone) starts one scan, not one per poll.
    private func startWatchingButtons() {
        sensorTask?.cancel()
        sensorTask = Task {
            var held: Set<String> = []
            while !Task.isCancelled {
                // Sleep only throws on cancellation; leave before touching the scanner, which
                // shutdown() is about to close.
                guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
                guard canScan else { continue }
                let states: [String: Bool]
                do {
                    states = try await scanner.sensors()
                } catch {
                    fail("Could not read the scanner's buttons", error)
                    await lostScanner()
                    return
                }
                let pressed = Set(states.filter(\.value).keys)
                defer { held = pressed }
                guard let name = pressed.subtracting(held).first else { continue }
                note("Scanner button “\(name)” pressed")
                scan()
            }
        }
    }

    // MARK: Helpers

    /// The geometry options for `rect`, origin first so the far edge never has to be below it,
    /// each in the type the backend declares (hp3900 uses whole millimetres, most use fixed-point).
    private func geometrySettings(for rect: CGRect) -> [(name: String, value: OptionValue)] {
        [("tl-x", rect.minX), ("tl-y", rect.minY), ("br-x", rect.maxX), ("br-y", rect.maxY)].map { name, millimetres in
            let kind = options.first { $0.name == name }?.kind
            return (name, kind == .fixed ? .fixed(Double(millimetres)) : .int(Int(millimetres)))
        }
    }

    private func number(_ name: String) -> Double {
        switch options.first(where: { $0.name == name })?.value {
        case .int(let value)?: Double(value)
        case .fixed(let value)?: value
        default: 0
        }
    }

    private func maximum(_ name: String) -> Double {
        if case .range(_, let max, _)? = options.first(where: { $0.name == name })?.constraint { return max }
        return 0
    }

    private var settingsSummary: String {
        let settings = ["source", "mode", "resolution", "depth"]
            .compactMap { name in options.first { $0.name == name }?.value.map(describe) }
        let film = flatbedFilm == .none || isFilmSource ? [] : ["\(flatbedFilm.rawValue.lowercased()) on flatbed"]
        return (settings + film).joined(separator: ", ")
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
