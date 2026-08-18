import Foundation
import CoreGraphics
import ImageIO
import Vision

enum OCR {
    static func scan(
        imageAt path: String,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) throws -> [[String: Any]] {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw MirrorError.invalidArgs("ocr could not read image at \(path)")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        var matches: [[String: Any]] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = visionToTopLeft(observation.boundingBox)
            matches.append([
                "text": candidate.string,
                "confidence": Double(candidate.confidence),
                "cx": box.cx,
                "cy": box.cy,
                "bbox": [
                    "x0": box.x0,
                    "y0": box.y0,
                    "x1": box.x1,
                    "y1": box.y1,
                ],
            ])
        }
        return matches
    }

    static func search(
        matches: [[String: Any]],
        query: String,
        x0: Double,
        y0: Double,
        x1: Double,
        y1: Double,
        limit: Int
    ) -> [String: Any] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var hits = matches.filter { match in
            guard let cx = (match["cx"] as? NSNumber)?.doubleValue,
                  let cy = (match["cy"] as? NSNumber)?.doubleValue else { return false }
            if cx < x0 || cx > x1 || cy < y0 || cy > y1 { return false }
            if !needle.isEmpty {
                guard let text = match["text"] as? String,
                      text.range(
                          of: needle,
                          options: [.caseInsensitive, .diacriticInsensitive]
                      ) != nil else { return false }
            }
            return true
        }

        hits.sort { left, right in
            let lc = left["confidence"] as? Double ?? 0
            let rc = right["confidence"] as? Double ?? 0
            if lc != rc { return lc > rc }
            let ly = left["cy"] as? Double ?? 1
            let ry = right["cy"] as? Double ?? 1
            return ly < ry
        }

        let cap = max(1, min(32, limit))
        if hits.count > cap { hits = Array(hits.prefix(cap)) }

        var best: [String: Any]?
        if !needle.isEmpty {
            let lowered = needle.lowercased()
            best = hits.first(where: {
                (($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == lowered
            })
        }
        best = best ?? hits.first

        var result: [String: Any] = [
            "ok": true,
            "found": best != nil,
            "query": query,
            "n": hits.count,
            "matches": hits,
        ]
        if let best {
            result["cx"] = best["cx"] as Any
            result["cy"] = best["cy"] as Any
            result["text"] = best["text"] as Any
            result["confidence"] = best["confidence"] as Any
            result["bbox"] = best["bbox"] as Any
        } else {
            result["cx"] = NSNull()
            result["cy"] = NSNull()
        }
        return result
    }

    static func recognize(
        imageAt path: String,
        query: String,
        x0: Double,
        y0: Double,
        x1: Double,
        y1: Double,
        limit: Int
    ) throws -> [String: Any] {
        search(
            matches: try scan(imageAt: path),
            query: query,
            x0: x0,
            y0: y0,
            x1: x1,
            y1: y1,
            limit: limit
        )
    }

    /// Vision boxes are normalized with origin at the bottom-left.
    /// Our screenshot coords are 0–1 with origin at the top-left.
    static func visionToTopLeft(_ box: CGRect) -> (
        cx: Double, cy: Double, x0: Double, y0: Double, x1: Double, y1: Double
    ) {
        (
            cx: box.midX,
            cy: 1.0 - box.midY,
            x0: box.minX,
            y0: 1.0 - box.maxY,
            x1: box.maxX,
            y1: 1.0 - box.minY
        )
    }
}
