import AppKit
import Vision

struct OCRService {
    static func recognizeText(
        in image: NSImage,
        languages: [String] = ["en", "es"],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(.failure(OCRError.invalidImage))
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion(.success(""))
                return
            }

            // Sort by position: top-to-bottom, then left-to-right.
            // Vision uses normalized coords where Y=0 is bottom, Y=1 is top.
            let sorted = observations.sorted { a, b in
                let ay = 1.0 - a.boundingBox.midY
                let by = 1.0 - b.boundingBox.midY
                // Group into rows (within 2% of page height = same line)
                if abs(ay - by) > 0.02 {
                    return ay < by
                }
                return a.boundingBox.midX < b.boundingBox.midX
            }

            let text = sorted
                .compactMap { obs -> String? in
                    guard let candidate = obs.topCandidates(1).first,
                          candidate.confidence > 0.3 else { return nil }
                    return candidate.string
                }
                .joined(separator: "\n")

            completion(.success(text))
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Async wrapper
    static func recognizeText(in image: NSImage, languages: [String] = ["en", "es"]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            recognizeText(in: image, languages: languages) { result in
                continuation.resume(with: result)
            }
        }
    }
}

enum OCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not convert image for text recognition."
        }
    }
}
