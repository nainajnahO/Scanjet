import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ScanFrame {
    /// Wraps the raw pixels without copying; 8- and 16-bit gray/RGB plus 1-bit lineart.
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let colorSpace: CGColorSpace?
        let bitmapInfo: CGBitmapInfo
        switch (channels, depth) {
        case (1, 1):
            colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case (1, 8):
            colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case (1, 16):
            colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little)
        case (3, 8):
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case (3, 16):
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little)
        default:
            return nil
        }
        guard let colorSpace else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: depth,
            bitsPerPixel: depth * channels,
            bytesPerRow: bytesPerLine,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            // SANE lineart sets 1 for black; CoreGraphics gray treats 1 as white. Flip via decode.
            decode: depth == 1 ? [1, 0] : nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Photographic negative of the frame. Byte-wise NOT is exact for 1-, 8- and 16-bit samples.
    func inverted() -> ScanFrame {
        var copy = self
        copy.pixels.withUnsafeMutableBytes { raw in
            for index in raw.indices { raw[index] = ~raw[index] }
        }
        return copy
    }

    /// Neutralises the colour cast of negative film: stretches each channel so its darkest and
    /// brightest 1% land on black and white, then matches the channels' mid-tones with a
    /// per-channel gamma (grey-world). Custom because vImage's ends-in stretch exists only for
    /// 8-bit and float; routing 16-bit RGB through float takes five conversions and more code.
    func balanced() -> ScanFrame {
        guard depth == 8 || depth == 16 else { return self }
        var copy = self
        copy.pixels.withUnsafeMutableBytes { raw in
            if depth == 8 {
                balanceChannels(raw.bindMemory(to: UInt8.self))
            } else {
                balanceChannels(raw.bindMemory(to: UInt16.self))
            }
        }
        return copy
    }

    private func balanceChannels<Sample: FixedWidthInteger & UnsignedInteger>(_ samples: UnsafeMutableBufferPointer<Sample>) {
        let levels = Int(Sample.max) + 1
        let samplesPerRow = bytesPerLine / MemoryLayout<Sample>.size
        let count = width * height

        func forEachSample(in channel: Int, _ body: (Int) -> Void) {
            for row in 0..<height {
                var index = row * samplesPerRow + channel
                for _ in 0..<width {
                    body(index)
                    index += channels
                }
            }
        }
        func apply(_ table: [Sample], to channel: Int) {
            forEachSample(in: channel) { samples[$0] = table[Int(samples[$0])] }
        }

        // Levels: clip 1% at each end of every channel.
        let clip = count / 100
        for channel in 0..<channels {
            var histogram = [Int](repeating: 0, count: levels)
            forEachSample(in: channel) { histogram[Int(samples[$0])] += 1 }
            var low = 0, counted = 0
            while low < levels - 1, counted + histogram[low] <= clip {
                counted += histogram[low]
                low += 1
            }
            var high = levels - 1
            counted = 0
            while high > low, counted + histogram[high] <= clip {
                counted += histogram[high]
                high -= 1
            }
            let scale = Double(levels - 1) / Double(max(high - low, 1))
            apply((0..<levels).map { Sample(clamping: Int((Double($0 - low) * scale).rounded())) }, to: channel)
        }

        // Grey world: gamma each colour channel so its mean matches the average of the three.
        guard channels == 3 else { return }
        let means = (0..<channels).map { channel in
            var sum = 0
            forEachSample(in: channel) { sum += Int(samples[$0]) }
            return Double(sum) / Double(count) / Double(levels - 1)
        }
        let target = means.reduce(0, +) / Double(channels)
        for channel in 0..<channels where means[channel] > 0 && means[channel] < 1 {
            let gamma = log(target) / log(means[channel])
            apply((0..<levels).map { value in
                Sample(clamping: Int((pow(Double(value) / Double(levels - 1), gamma) * Double(levels - 1)).rounded()))
            }, to: channel)
        }
    }

    /// Writes the frame with ImageIO. PNG and TIFF keep 16-bit samples; JPEG is 8-bit.
    func write(to url: URL, as type: UTType) throws {
        guard let image = cgImage else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Unsupported pixel format"])
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not create \(url.lastPathComponent)"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.lastPathComponent)"])
        }
    }
}
