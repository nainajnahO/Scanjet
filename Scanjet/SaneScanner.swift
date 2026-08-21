import CSane
import Foundation
import Synchronization

nonisolated struct SaneError: LocalizedError {
    let status: SANE_Status
    let context: String

    var errorDescription: String? {
        "\(context): \(String(cString: sane_strstatus(status)))"
    }
}

nonisolated enum OptionKind: Sendable, Equatable {
    case bool, int, fixed, string, button, group
}

nonisolated enum OptionConstraint: Sendable, Equatable {
    case none
    case range(min: Int, max: Int, step: Int)
    case intList([Int])
    case stringList([String])
}

nonisolated enum OptionValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case fixed(Double)
    case string(String)
}

/// One SANE option descriptor plus its current value, as a plain value type the UI can render.
nonisolated struct ScanOption: Sendable, Identifiable {
    let index: Int32
    let name: String
    let title: String
    let detail: String
    let kind: OptionKind
    let unit: String
    let constraint: OptionConstraint
    let isActive: Bool
    let isSettable: Bool
    let isAdvanced: Bool
    /// Reported by the hardware (front-panel buttons etc.) and only readable.
    let isSensor: Bool
    /// Byte size of the option's value buffer (string options need it when writing back).
    let size: Int
    /// nil for groups, buttons, inactive options, and array-valued options (gamma tables).
    var value: OptionValue?

    var id: Int32 { index }
}

/// Raw pixels straight from the backend: tightly packed rows, `depth` bits per sample,
/// 1 or 3 samples per pixel, 16-bit samples in host byte order, lineart 1 = black.
nonisolated struct ScanFrame: Sendable {
    let width: Int
    let height: Int
    let depth: Int
    let channels: Int
    let bytesPerLine: Int
    /// Lines the backend announced before reading; fewer arrive when it gives up early.
    let announcedHeight: Int
    var pixels: Data
}

/// Owns the SANE handle. Every SANE call runs on this actor's dedicated serial queue so a
/// minutes-long `sane_read` loop blocks only that thread, never the cooperative pool.
actor SaneScanner {
    nonisolated let queue = DispatchSerialQueue(label: "Scanjet.SaneScanner")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    // `sane_cancel` is the one call the SANE standard allows from another thread while a read is
    // in progress, so the handle must be reachable without hopping onto the (busy) actor.
    private nonisolated(unsafe) var handle: SANE_Handle?

    // hp3900's sane_cancel only sets a flag, and sane_start clears that flag after it begins
    // (RTS_Scanner_StartScan), so a cancel that lands during warm-up/calibration is lost. This
    // remembers the request so scan() can re-issue it once sane_start returns.
    private nonisolated let cancelRequested = Atomic<Bool>(false)

    private var chunk = [SANE_Byte](repeating: 0, count: 64 * 1024)

    nonisolated struct DeviceInfo: Sendable {
        let name: String
        let vendor: String
        let model: String
    }

    // MARK: Lifecycle

    /// Initialises SANE and opens the first scanner it finds.
    func connect() throws -> DeviceInfo {
        disconnect()
        var version: SANE_Int = 0
        try check(sane_init(&version, nil), "sane_init")

        var list: UnsafeMutablePointer<UnsafePointer<SANE_Device>?>?
        try check(sane_get_devices(&list, SANE_FALSE), "sane_get_devices")
        guard let first = list?.pointee?.pointee else {
            sane_exit()
            throw SaneError(status: SANE_STATUS_NO_DOCS, context: "No scanner found")
        }
        let info = DeviceInfo(
            name: String(cString: first.name),
            vendor: String(cString: first.vendor),
            model: String(cString: first.model)
        )

        var opened: SANE_Handle?
        try check(sane_open(info.name, &opened), "sane_open \(info.name)")
        handle = opened
        return info
    }

    func disconnect() {
        guard let handle else { return }
        sane_close(handle)
        sane_exit()
        self.handle = nil
    }

    // MARK: Options

    func options() throws -> [ScanOption] {
        let handle = try openHandle()
        var count: SANE_Int = 0
        try check(sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &count, nil), "option count")
        return try (1..<count).compactMap { try option(at: $0, handle: handle) }
    }

    /// Sets one option. Returns true when the backend says other options may have changed.
    @discardableResult
    func set(_ name: String, to value: OptionValue) throws -> Bool {
        let handle = try openHandle()
        guard let option = try options().first(where: { $0.name == name }) else {
            throw SaneError(status: SANE_STATUS_INVAL, context: "No option named \(name)")
        }
        var info: SANE_Int = 0
        let status: SANE_Status
        switch (option.kind, value) {
        case (.bool, .bool(let flag)):
            var word: SANE_Word = flag ? SANE_TRUE : SANE_FALSE
            status = sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &word, &info)
        case (.int, .int(let number)):
            var word = SANE_Word(number)
            status = sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &word, &info)
        case (.fixed, .fixed(let number)):
            var word = SANE_Word((number * 65536).rounded())
            status = sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &word, &info)
        case (.string, .string(let text)):
            // The backend may rewrite the buffer with the value it actually applied.
            var buffer = [CChar](repeating: 0, count: max(option.size, text.utf8.count + 1))
            text.utf8CString.withUnsafeBufferPointer { buffer.replaceSubrange(0..<$0.count, with: $0) }
            status = sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &buffer, &info)
        default:
            throw SaneError(status: SANE_STATUS_INVAL, context: "\(name) does not take \(value)")
        }
        try check(status, "set \(name)")
        return info & SANE_INFO_RELOAD_OPTIONS != 0
    }

    func press(_ name: String) throws {
        let handle = try openHandle()
        guard let option = try options().first(where: { $0.name == name }), option.kind == .button else {
            throw SaneError(status: SANE_STATUS_INVAL, context: "No button named \(name)")
        }
        var ignored: SANE_Word = 0
        try check(sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &ignored, nil), "press \(name)")
    }

    /// Current state of every hardware sensor (front-panel buttons), by option name.
    func sensors() throws -> [String: Bool] {
        var states: [String: Bool] = [:]
        for option in try options() where option.isSensor && option.isActive {
            if case .bool(let pressed) = option.value { states[option.name] = pressed }
        }
        return states
    }

    // MARK: Scanning

    /// Runs one scan with the current options. `progress` receives (lines read, total lines);
    /// total is 0 while the backend does not know it yet.
    func scan(progress: @escaping @Sendable (Int, Int) -> Void) throws -> ScanFrame {
        let handle = try openHandle()
        try check(sane_start(handle), "sane_start")
        defer {
            // hp3900's sane_cancel only raises a flag; the actual stop (park the carriage, arm the
            // lamp timer) runs on the next sane_read. A scan that ends on the backend's error path
            // skips that stop, so always give it one more read to do it.
            sane_cancel(handle)
            var length: SANE_Int = 0
            _ = sane_read(handle, &chunk, SANE_Int(chunk.count), &length)
        }
        if cancelRequested.load(ordering: .acquiring) { sane_cancel(handle) }

        var params = SANE_Parameters()
        try check(sane_get_parameters(handle, &params), "sane_get_parameters")
        let channels: Int
        switch params.format {
        case SANE_FRAME_GRAY: channels = 1
        case SANE_FRAME_RGB: channels = 3
        default:
            throw SaneError(status: SANE_STATUS_UNSUPPORTED, context: "Three-pass colour frames")
        }
        let bytesPerLine = Int(params.bytes_per_line)
        let knownLines = Int(params.lines)
        var pixels = Data()
        if knownLines > 0 { pixels.reserveCapacity(bytesPerLine * knownLines) }

        // Report roughly every half percent so a 4800 dpi scan does not flood the main actor.
        let reportEvery = max(knownLines / 200, 1)
        var lastReported = 0
        readLoop: while true {
            var length: SANE_Int = 0
            let status = sane_read(handle, &chunk, SANE_Int(chunk.count), &length)
            switch status {
            case SANE_STATUS_GOOD:
                pixels.append(contentsOf: chunk[0..<Int(length)])
                let lines = pixels.count / bytesPerLine
                if lines - lastReported >= reportEvery || lines == knownLines {
                    lastReported = lines
                    progress(lines, max(knownLines, 0))
                }
            case SANE_STATUS_EOF:
                break readLoop
            case SANE_STATUS_CANCELLED:
                throw CancellationError()
            default:
                throw SaneError(status: status, context: "sane_read")
            }
        }

        let height = pixels.count / bytesPerLine
        return ScanFrame(
            width: Int(params.pixels_per_line),
            height: height,
            depth: Int(params.depth),
            channels: channels,
            bytesPerLine: bytesPerLine,
            announcedHeight: knownLines,
            pixels: pixels
        )
    }

    nonisolated func cancel() {
        cancelRequested.store(true, ordering: .releasing)
        if let handle { sane_cancel(handle) }
    }

    /// Call before each scan, before the UI can offer Cancel, so a stale request can't cancel it.
    nonisolated func clearCancel() {
        cancelRequested.store(false, ordering: .releasing)
    }

    // MARK: Helpers

    private func openHandle() throws -> SANE_Handle {
        guard let handle else {
            throw SaneError(status: SANE_STATUS_INVAL, context: "Scanner is not connected")
        }
        return handle
    }

    private func check(_ status: SANE_Status, _ context: String) throws {
        guard status == SANE_STATUS_GOOD else { throw SaneError(status: status, context: context) }
    }

    private func option(at index: SANE_Int, handle: SANE_Handle) throws -> ScanOption? {
        guard let descriptor = sane_get_option_descriptor(handle, index)?.pointee else { return nil }
        let kind: OptionKind
        switch descriptor.type {
        case SANE_TYPE_BOOL: kind = .bool
        case SANE_TYPE_INT: kind = .int
        case SANE_TYPE_FIXED: kind = .fixed
        case SANE_TYPE_STRING: kind = .string
        case SANE_TYPE_BUTTON: kind = .button
        default: kind = .group
        }
        let cap = descriptor.cap
        let isActive = cap & SANE_CAP_INACTIVE == 0
        let isSettable = cap & SANE_CAP_SOFT_SELECT != 0
        let isSensor = cap & SANE_CAP_SOFT_DETECT != 0 && !isSettable
        let isWord = descriptor.size == MemoryLayout<SANE_Word>.size

        var value: OptionValue?
        if isActive {
            switch kind {
            case .bool, .int, .fixed:
                // Array-valued options (gamma tables, size > one word) are not exposed in the UI.
                guard isWord else { break }
                var word: SANE_Word = 0
                try check(sane_control_option(handle, index, SANE_ACTION_GET_VALUE, &word, nil), "get option \(index)")
                switch kind {
                case .bool: value = .bool(word != SANE_FALSE)
                case .int: value = .int(Int(word))
                default: value = .fixed(Double(word) / 65536)
                }
            case .string:
                var buffer = [CChar](repeating: 0, count: Int(descriptor.size))
                try check(sane_control_option(handle, index, SANE_ACTION_GET_VALUE, &buffer, nil), "get option \(index)")
                value = .string(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            case .button, .group:
                break
            }
        }

        return ScanOption(
            index: index,
            name: descriptor.name.map { String(cString: $0) } ?? "",
            title: descriptor.title.map { String(cString: $0) } ?? "",
            detail: descriptor.desc.map { String(cString: $0) } ?? "",
            kind: kind,
            unit: Self.unitLabel(descriptor.unit),
            constraint: Self.constraint(of: descriptor),
            isActive: isActive,
            isSettable: isSettable,
            isAdvanced: cap & SANE_CAP_ADVANCED != 0,
            isSensor: isSensor,
            size: Int(descriptor.size),
            value: value
        )
    }

    private static func constraint(of descriptor: SANE_Option_Descriptor) -> OptionConstraint {
        switch descriptor.constraint_type {
        case SANE_CONSTRAINT_RANGE:
            guard let range = descriptor.constraint.range?.pointee else { return .none }
            return .range(min: Int(range.min), max: Int(range.max), step: Int(range.quant))
        case SANE_CONSTRAINT_WORD_LIST:
            guard let list = descriptor.constraint.word_list else { return .none }
            let count = Int(list[0])
            return .intList((1...max(count, 1)).prefix(count).map { Int(list[$0]) })
        case SANE_CONSTRAINT_STRING_LIST:
            guard let list = descriptor.constraint.string_list else { return .none }
            var strings: [String] = []
            var cursor = 0
            while let entry = list[cursor] {
                strings.append(String(cString: entry))
                cursor += 1
            }
            return .stringList(strings)
        default:
            return .none
        }
    }

    private static func unitLabel(_ unit: SANE_Unit) -> String {
        switch unit {
        case SANE_UNIT_PIXEL: "px"
        case SANE_UNIT_BIT: "bit"
        case SANE_UNIT_MM: "mm"
        case SANE_UNIT_DPI: "dpi"
        case SANE_UNIT_PERCENT: "%"
        case SANE_UNIT_MICROSECOND: "µs"
        default: ""
        }
    }
}
