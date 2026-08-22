import CSane
import Foundation
import Synchronization

nonisolated struct SaneError: LocalizedError {
    let status: SANE_Status
    let context: String

    var errorDescription: String? {
        "\(context): \(String(cString: sane_strstatus(status)))"
    }

    /// The backend could not talk to the hardware; the scanner is as good as unplugged.
    var isDeviceLost: Bool { status == SANE_STATUS_IO_ERROR }
}

nonisolated enum OptionKind: Sendable, Equatable {
    case bool, int, fixed, string, button, group
}

/// Limits in the option's own units: whole numbers for `.int`, real values for `.fixed`.
nonisolated enum OptionConstraint: Sendable, Equatable {
    case none
    case range(min: Double, max: Double, step: Double)
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
        do {
            var list: UnsafeMutablePointer<UnsafePointer<SANE_Device>?>?
            try check(sane_get_devices(&list, SANE_FALSE), "sane_get_devices")
            guard let first = list?.pointee?.pointee else {
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
        } catch {
            // Every sane_init needs its sane_exit, or the next connect() initialises twice.
            sane_exit()
            throw error
        }
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
        return try descriptors(handle).map { option in
            var option = option
            option.value = try value(of: option, handle: handle)
            return option
        }
    }

    /// Sets one option, clamped to its constraint the way SANE's own `sanei_constrain_value`
    /// does: hp3900 stores whatever it is given, so an out-of-range value would otherwise be
    /// accepted and then fail every scan.
    func set(_ name: String, to value: OptionValue) throws {
        let handle = try openHandle()
        let option = try descriptor(named: name, handle: handle)
        // Array-valued options (gamma tables) take a whole table; writing one word would make
        // the backend read 256 KB off a 4-byte stack slot.
        if [.bool, .int, .fixed].contains(option.kind), option.size != MemoryLayout<SANE_Word>.size {
            throw SaneError(status: SANE_STATUS_UNSUPPORTED, context: "\(name) is array-valued")
        }
        var info: SANE_Int = 0
        let status: SANE_Status
        switch (option.kind, value) {
        case (.bool, .bool(let flag)):
            var word: SANE_Word = flag ? SANE_TRUE : SANE_FALSE
            status = sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &word, &info)
        case (.int, .int(let number)):
            var word = try Self.word(Double(Self.constrain(Double(number), to: option.constraint)), for: name)
            status = sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &word, &info)
        case (.fixed, .fixed(let number)):
            var word = try Self.word(Self.constrain(number, to: option.constraint) * 65536, for: name)
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
    }

    func press(_ name: String) throws {
        let handle = try openHandle()
        let option = try descriptor(named: name, handle: handle)
        guard option.kind == .button else {
            throw SaneError(status: SANE_STATUS_INVAL, context: "\(name) is not a button")
        }
        var ignored: SANE_Word = 0
        try check(sane_control_option(handle, option.index, SANE_ACTION_SET_VALUE, &ignored, nil), "press \(name)")
    }

    /// Current state of every hardware sensor (front-panel buttons), by option name. Reads only
    /// the sensors: on hp3900 every button read clears the press, so sweeping all options here
    /// would swallow presses.
    func sensors() throws -> [String: Bool] {
        let handle = try openHandle()
        var states: [String: Bool] = [:]
        for option in try descriptors(handle) where option.isSensor && option.isActive && option.kind == .bool {
            if case .bool(let pressed)? = try value(of: option, handle: handle) { states[option.name] = pressed }
        }
        return states
    }

    // MARK: Scanning

    /// Runs one scan with the current options. `progress` receives (lines read, total lines);
    /// total is 0 while the backend does not know it yet.
    func scan(progress: @escaping @Sendable (Int, Int) -> Void) throws -> ScanFrame {
        let handle = try openHandle()
        defer {
            // hp3900's sane_cancel only raises a flag; the actual stop (park the carriage, arm the
            // lamp timer) runs on the next sane_read. A scan that ends on the backend's error path
            // skips that stop — including sane_start failing after it has already moved the head
            // — so always give it one more read to do it. Both are no-ops when nothing started.
            sane_cancel(handle)
            var length: SANE_Int = 0
            _ = sane_read(handle, &chunk, SANE_Int(chunk.count), &length)
        }
        try check(sane_start(handle), "sane_start")
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
        guard bytesPerLine > 0 else {
            throw SaneError(status: SANE_STATUS_INVAL, context: "Backend reported an empty scan line")
        }
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

    /// Every option's descriptor, values not yet read. Pure memory reads, no device traffic.
    private func descriptors(_ handle: SANE_Handle) throws -> [ScanOption] {
        var count: SANE_Int = 0
        try check(sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &count, nil), "option count")
        return (1..<max(count, 1)).compactMap { index in
            sane_get_option_descriptor(handle, index).map { Self.option(from: $0.pointee, at: index) }
        }
    }

    private func descriptor(named name: String, handle: SANE_Handle) throws -> ScanOption {
        guard let option = try descriptors(handle).first(where: { $0.name == name }) else {
            throw SaneError(status: SANE_STATUS_INVAL, context: "No option named \(name)")
        }
        return option
    }

    private func value(of option: ScanOption, handle: SANE_Handle) throws -> OptionValue? {
        guard option.isActive else { return nil }
        switch option.kind {
        case .bool, .int, .fixed:
            // Array-valued options (gamma tables, size > one word) are not exposed in the UI.
            guard option.size == MemoryLayout<SANE_Word>.size else { return nil }
            var word: SANE_Word = 0
            try check(sane_control_option(handle, option.index, SANE_ACTION_GET_VALUE, &word, nil), "get \(option.name)")
            switch option.kind {
            case .bool: return .bool(word != SANE_FALSE)
            case .int: return .int(Int(word))
            default: return .fixed(Double(word) / 65536)
            }
        case .string:
            var buffer = [CChar](repeating: 0, count: option.size)
            try check(sane_control_option(handle, option.index, SANE_ACTION_GET_VALUE, &buffer, nil), "get \(option.name)")
            return .string(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        case .button, .group:
            return nil
        }
    }

    private static func option(from descriptor: SANE_Option_Descriptor, at index: SANE_Int) -> ScanOption {
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
        let isSettable = cap & SANE_CAP_SOFT_SELECT != 0
        return ScanOption(
            index: index,
            name: descriptor.name.map { String(cString: $0) } ?? "",
            title: descriptor.title.map { String(cString: $0) } ?? "",
            detail: descriptor.desc.map { String(cString: $0) } ?? "",
            kind: kind,
            unit: unitLabel(descriptor.unit),
            constraint: constraint(of: descriptor, kind: kind),
            isActive: cap & SANE_CAP_INACTIVE == 0,
            isSettable: isSettable,
            isAdvanced: cap & SANE_CAP_ADVANCED != 0,
            isSensor: cap & SANE_CAP_SOFT_DETECT != 0 && !isSettable,
            size: Int(descriptor.size),
            value: nil
        )
    }

    /// A SANE word from an already-constrained number; what's left over is a backend whose
    /// range itself overflows, or an unconstrained option fed an absurd value.
    private static func word(_ number: Double, for name: String) throws -> SANE_Word {
        guard let word = SANE_Word(exactly: number.rounded()) else {
            throw SaneError(status: SANE_STATUS_INVAL, context: "\(name) cannot take \(number.formatted())")
        }
        return word
    }

    /// Clamps to a range (rounded to its step) or snaps to the nearest listed value.
    private static func constrain(_ number: Double, to constraint: OptionConstraint) -> Double {
        switch constraint {
        case .range(let low, let high, let step):
            let clamped = min(max(number, low), high)
            guard step > 0 else { return clamped }
            return min(low + ((clamped - low) / step).rounded() * step, high)
        case .intList(let values):
            return values.min { abs(Double($0) - number) < abs(Double($1) - number) }.map(Double.init) ?? number
        case .none, .stringList:
            return number
        }
    }

    private static func constraint(of descriptor: SANE_Option_Descriptor, kind: OptionKind) -> OptionConstraint {
        // Fixed-point options keep their limits as 16.16 words; report them in real units.
        let scale: Double = kind == .fixed ? 65536 : 1
        switch descriptor.constraint_type {
        case SANE_CONSTRAINT_RANGE:
            guard let range = descriptor.constraint.range?.pointee else { return .none }
            return .range(min: Double(range.min) / scale, max: Double(range.max) / scale, step: Double(range.quant) / scale)
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
