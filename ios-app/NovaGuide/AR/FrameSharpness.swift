import CoreGraphics
import CoreVideo

/// A live picture looks sharp to the eye, but a single frame taken while the hand moves is not. These pick the frame
/// worth sending from the last moments.
enum FrameSharpness {
    /// The newest frame this close to the sharpest one wins, so a task doesn't read an older moment for nothing.
    static let closeEnough = 0.85

    /// How much fine detail the middle of the picture has: the mean squared Laplacian of the brightness, on a sparse
    /// grid so it costs well under a millisecond. Only comparable between frames of the same scene.
    static func score(luma: UnsafePointer<UInt8>, rowBytes: Int, width: Int, height: Int, gap: Int = 2, step: Int = 4) -> Double {
        let left = max(width / 5, gap), right = min(width - width / 5, width - gap)
        let top = max(height / 5, gap), bottom = min(height - height / 5, height - gap)
        guard left < right, top < bottom else { return 0 }
        var total = 0.0
        var count = 0
        for y in stride(from: top, to: bottom, by: step) {
            let row = luma + y * rowBytes
            for x in stride(from: left, to: right, by: step) {
                let around = Int(row[x - gap]) + Int(row[x + gap]) + Int(row[x - gap * rowBytes]) + Int(row[x + gap * rowBytes])
                let laplacian = Double(4 * Int(row[x]) - around)
                total += laplacian * laplacian
                count += 1
            }
        }
        return total / Double(max(count, 1))
    }

    /// The score of a camera frame, from its brightness plane.
    static func score(_ pixelBuffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return 0 }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        return score(luma: base.assumingMemoryBound(to: UInt8.self),
                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                     width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                     height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
    }

    /// Which frame to use, from scores ordered oldest to newest.
    static func choose(scores: [Double]) -> Int? {
        guard let best = scores.max() else { return nil }
        return scores.lastIndex { $0 >= best * closeEnough }
    }
}

/// How bright the picture is behind the hand, so it is drawn in the color that shows.
enum PictureBrightness {
    /// The mean brightness, 0 to 255, in a small square around a point given from 0 to 1.
    static func mean(luma: UnsafePointer<UInt8>, rowBytes: Int, width: Int, height: Int, around point: CGPoint, reach: CGFloat = 0.06, step: Int = 8) -> Double? {
        let left = max(Int((point.x - reach) * CGFloat(width)), 0), right = min(Int((point.x + reach) * CGFloat(width)), width - 1)
        let top = max(Int((point.y - reach) * CGFloat(height)), 0), bottom = min(Int((point.y + reach) * CGFloat(height)), height - 1)
        guard left <= right, top <= bottom else { return nil }
        var total = 0
        var count = 0
        for y in stride(from: top, through: bottom, by: step) {
            for x in stride(from: left, through: right, by: step) {
                total += Int(luma[y * rowBytes + x])
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : nil
    }

    static func mean(_ pixelBuffer: CVPixelBuffer, around point: CGPoint) -> Double? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        return mean(luma: base.assumingMemoryBound(to: UInt8.self), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                    width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), around: point)
    }

    /// True for a white hand on a dark picture. In between it keeps its color, so the hand doesn't flicker.
    static func isDark(_ brightness: Double, was: Bool) -> Bool {
        if brightness < 95 { return true }
        if brightness > 150 { return false }
        return was
    }
}
