import CoreGraphics
import Foundation
import ImageIO

struct VisualObservation {
    let signature: String
    let structuralHash: String
}

enum VisualComparison {
    static let signatureVersion = "rgb16"
    static let sampleSize = 16
    static let materialDifferenceThreshold = 6.0
    static let structuralDifferenceThreshold = 8

    static func observation(at url: URL) throws -> VisualObservation {
        let image = try image(at: url)
        return VisualObservation(
            signature: try signature(of: image),
            structuralHash: try structuralHash(of: image)
        )
    }

    static func signature(at url: URL) throws -> String {
        try signature(of: image(at: url))
    }

    static func signature(of image: CGImage) throws -> String {
        let width = sampleSize
        let height = sampleSize
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw MirrorError.captureFailed("could not create visual comparison context")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            rgb.append(pixels[offset])
            rgb.append(pixels[offset + 1])
            rgb.append(pixels[offset + 2])
        }
        return "\(signatureVersion):" + rgb.map { String(format: "%02x", $0) }.joined()
    }

    static func distance(_ left: String, _ right: String) throws -> Double {
        let prefix = "\(signatureVersion):"
        guard left.hasPrefix(prefix), right.hasPrefix(prefix),
              let leftBytes = decodeHex(String(left.dropFirst(prefix.count))),
              let rightBytes = decodeHex(String(right.dropFirst(prefix.count))),
              leftBytes.count == sampleSize * sampleSize * 3,
              rightBytes.count == leftBytes.count else {
            throw MirrorError.invalidArgs("invalid \(signatureVersion) visual signature")
        }
        let total = zip(leftBytes, rightBytes).reduce(0) { partial, pair in
            partial + abs(Int(pair.0) - Int(pair.1))
        }
        return Double(total) / Double(leftBytes.count)
    }

    static func distance(between left: URL, and right: URL) throws -> Double {
        try distance(signature(at: left), signature(at: right))
    }

    static func structuralHash(of image: CGImage) throws -> String {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw MirrorError.captureFailed("could not create structural comparison context")
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var value: UInt64 = 0
        for row in 0..<height {
            let offset = row * width
            for column in 0..<(width - 1) {
                value <<= 1
                if pixels[offset + column] > pixels[offset + column + 1] { value |= 1 }
            }
        }
        return String(format: "%016llx", value)
    }

    static func structuralDistance(_ left: String, _ right: String) throws -> Int {
        guard left.count == 16, right.count == 16,
              let leftValue = UInt64(left, radix: 16),
              let rightValue = UInt64(right, radix: 16) else {
            throw MirrorError.invalidArgs("invalid structural visual hash")
        }
        return (leftValue ^ rightValue).nonzeroBitCount
    }

    static func materiallyDifferent(_ left: String, _ right: String) throws -> Bool {
        try distance(left, right) > materialDifferenceThreshold
    }

    static func materiallyDifferent(_ left: VisualObservation, _ right: VisualObservation) throws -> Bool {
        try distance(left.signature, right.signature) > materialDifferenceThreshold
            || structuralDistance(left.structuralHash, right.structuralHash) > structuralDifferenceThreshold
    }

    private static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MirrorError.captureFailed("could not read image for visual comparison")
        }
        return image
    }

    private static func decodeHex(_ value: String) -> [UInt8]? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
