import CoreGraphics
import Foundation

// Helpers shared by features that read screen pixels (Capture, the Rolltop Bar's backdrop
// sampling). ScreenCaptureKit calls must only run with the Screen Recording grant
// (`CGPreflightScreenCaptureAccess()`): listing shareable content without it prompts.

nonisolated enum WatchdogError: LocalizedError {
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let step): "Timed out (\(step))"
        }
    }
}

/// Carries a value that is safe to hand over (immutable after creation) across isolation.
nonisolated struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Bridges a callback API to async with a hard deadline. Unlike a task group, it returns
/// at the deadline even if the callback never fires.
nonisolated enum Watchdog {
    static func run<T: Sendable>(seconds: Double, step: String,
                       _ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            once.set(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                once.resume(.failure(WatchdogError.timedOut(step)))
            }
            start { once.resume($0) }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        func set(_ continuation: CheckedContinuation<T, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ result: Result<T, Error>) {
            let continuation: CheckedContinuation<T, Error>? = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }
}

/// An 8-bit RGBA, premultiplied, top-row-first copy of an image.
nonisolated struct PixelBuffer: Sendable, Equatable {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytes: bytes)
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

    /// Unpremultiplied colour of a pixel (0…1), nil when transparent.
    func color(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double)? {
        let i = (y * width + x) * 4
        let a = Double(bytes[i + 3]) / 255
        guard a > 0 else { return nil }
        return (min(1, Double(bytes[i]) / 255 / a), min(1, Double(bytes[i + 1]) / 255 / a), min(1, Double(bytes[i + 2]) / 255 / a), a)
    }

    /// Smallest rect (pixels, top-left origin) holding every pixel with alpha above `threshold`.
    func alphaBounds(threshold: UInt8 = 8) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func cropped(to rect: CGRect) -> PixelBuffer {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width > 0, r.height > 0 else { return PixelBuffer(width: 1, height: 1, bytes: [0, 0, 0, 0]) }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = ((y0 + y) * width + x0) * 4
            out.replaceSubrange(y * w * 4 ..< (y + 1) * w * 4, with: bytes[src ..< src + w * 4])
        }
        return PixelBuffer(width: w, height: h, bytes: out)
    }

    func makeImage() -> CGImage? {
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
