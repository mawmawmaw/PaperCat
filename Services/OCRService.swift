import AppKit
import Vision

struct OCRService {
    static func recognizeText(
        in image: NSImage,
        languages: [String] = ["en"],
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

            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
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
    static func recognizeText(in image: NSImage, languages: [String] = ["en"]) async throws -> String {
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
