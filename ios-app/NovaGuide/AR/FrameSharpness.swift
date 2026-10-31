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
