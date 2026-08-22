import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// nonisolated: the app defaults to main-actor isolation, and these run off the main actor.
nonisolated extension ScanFrame {
    /// Wraps the raw pixels without copying; 8- and 16-bit gray/RGB plus 1-bit lineart.
    var cgImage: CGImage? {
        guard channels == 1 || channels == 3, depth == 8 || depth == 16 || (depth == 1 && channels == 1),
              let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: channels == 1 ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB)
        else { return nil }
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if depth == 16 { bitmapInfo.formUnion(.byteOrder16Little) }
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

    /// An 8-bit copy no larger than `maxPixels` on its long side, for display. Core Animation
    /// cannot texture images over 16384 px, and a 2400 dpi bed is 20k × 28k 16-bit samples.
    func displayImage(maxPixels: Int = 4096) -> CGImage? {
        guard let image = cgImage else { return nil }
        let scale = min(1, Double(maxPixels) / Double(max(width, height)))
        let size = (width: max(Int(Double(width) * scale), 1), height: max(Int(Double(height) * scale), 1))
        let gray = channels == 1
        guard let colorSpace = CGColorSpace(name: gray ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: (gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.noneSkipLast).rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// The frame with the toolbar toggles applied. Invert alone is a byte-wise NOT; with Balance
    /// on, the inversion folds into the balance tables so the pixels are rewritten once.
    func processed(invert: Bool, balance: Bool) -> ScanFrame {
        guard balance, depth == 8 || depth == 16 else {
            return invert ? inverted() : self
        }
        var copy = self
        copy.pixels.withUnsafeMutableBytes { raw in
            if depth == 8 {
                balanceChannels(raw.bindMemory(to: UInt8.self), invert: invert)
            } else {
                balanceChannels(raw.bindMemory(to: UInt16.self), invert: invert)
            }
        }
        return copy
    }

    /// Photographic negative of the frame. Byte-wise NOT is exact for 1-, 8- and 16-bit samples.
    private func inverted() -> ScanFrame {
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
    ///
    /// One read pass builds the histograms and one write pass applies the composed tables; the
    /// means the gamma needs come from the histograms. Plain loops over raw pointers because
    /// closures per sample make a Debug build take minutes on a 2400 dpi frame.
    private func balanceChannels<Sample: FixedWidthInteger & UnsignedInteger>(
        _ samples: UnsafeMutableBufferPointer<Sample>, invert: Bool
    ) {
        let levels = Int(Sample.max) + 1
        let top = levels - 1
        let samplesPerRow = bytesPerLine / MemoryLayout<Sample>.size
        let count = width * height
        let clip = count / 100

        // Histogram of what the balance sees: the inverted sample when Invert is on.
        var histograms = [Int](repeating: 0, count: levels * channels)
        histograms.withUnsafeMutableBufferPointer { histograms in
            for row in 0..<height {
                var index = row * samplesPerRow
                for _ in 0..<width {
                    for channel in 0..<channels {
                        let value = Int(samples[index])
                        histograms[channel * levels + (invert ? top - value : value)] += 1
                        index += 1
                    }
                }
            }
        }

        // Levels per channel: clip 1% at each end, stretch the rest to the full range.
        var tables = [Sample](repeating: 0, count: levels * channels)
        var means = [Double](repeating: 0, count: channels)
        for channel in 0..<channels {
            let histogram = histograms[channel * levels..<(channel + 1) * levels]
            var low = 0, counted = 0
            while low < top, counted + histogram[histogram.startIndex + low] <= clip {
                counted += histogram[histogram.startIndex + low]
                low += 1
            }
            var high = top
            counted = 0
            while high > low, counted + histogram[histogram.startIndex + high] <= clip {
                counted += histogram[histogram.startIndex + high]
                high -= 1
            }
            let scale = Double(top) / Double(max(high - low, 1))
            var sum = 0
            for value in 0..<levels {
                let stretched = Sample(clamping: Int((Double(value - low) * scale).rounded()))
                tables[channel * levels + value] = stretched
                sum += histogram[histogram.startIndex + value] * Int(stretched)
            }
            means[channel] = Double(sum) / Double(count) / Double(top)
        }

        // Grey world: gamma each colour channel so its mean matches the average of the three.
        if channels == 3 {
            let target = means.reduce(0, +) / Double(channels)
            for channel in 0..<channels where means[channel] > 0 && means[channel] < 1 {
                let gamma = log(target) / log(means[channel])
                for value in 0..<levels {
                    let stretched = Double(tables[channel * levels + value]) / Double(top)
                    tables[channel * levels + value] = Sample(clamping: Int((pow(stretched, gamma) * Double(top)).rounded()))
                }
            }
        }

        // Inversion is a table lookup too: the stored sample v is the balance input top - v.
        if invert {
            for channel in 0..<channels {
                let base = channel * levels
                for value in 0..<(levels / 2) {
                    tables.swapAt(base + value, base + top - value)
                }
            }
        }

        tables.withUnsafeBufferPointer { tables in
            for row in 0..<height {
                var index = row * samplesPerRow
                for _ in 0..<width {
                    for channel in 0..<channels {
                        samples[index] = tables[channel * levels + Int(samples[index])]
                        index += 1
                    }
                }
            }
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
