import AppKit
import CoreImage
import Vision

struct ImageProcessor {

    // MARK: - Adjustments

    static func applyAdjustments(
        to image: NSImage,
        brightness: Double,
        contrast: Double,
        sharpness: Double
    ) -> NSImage? {
        guard let ciImage = ciImage(from: image) else { return nil }
        let context = CIContext()

        // Color controls: brightness + contrast
        var output = ciImage
        if brightness != 0 || contrast != 1.0 {
            guard let colorFilter = CIFilter(name: "CIColorControls") else { return nil }
            colorFilter.setValue(output, forKey: kCIInputImageKey)
            colorFilter.setValue(brightness, forKey: kCIInputBrightnessKey)
            colorFilter.setValue(contrast, forKey: kCIInputContrastKey)
            guard let result = colorFilter.outputImage else { return nil }
            output = result
        }

        // Sharpness
        if sharpness > 0 {
            guard let sharpFilter = CIFilter(name: "CISharpenLuminance") else { return nil }
            sharpFilter.setValue(output, forKey: kCIInputImageKey)
            sharpFilter.setValue(sharpness, forKey: kCIInputSharpnessKey)
            guard let result = sharpFilter.outputImage else { return nil }
            output = result
        }

        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: image.size)
    }

    // MARK: - Auto-crop via rectangle detection

    static func autoCrop(image: NSImage, completion: @escaping (NSImage?) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(nil)
            return
        }

        let request = VNDetectRectanglesRequest { request, error in
            guard let results = request.results as? [VNRectangleObservation],
                  let rect = results.first else {
                completion(nil)
                return
            }

            // Apply perspective correction
            guard let ciImage = ciImage(from: image) else {
                completion(nil)
                return
            }

            let imageSize = ciImage.extent.size

            let topLeft = CGPoint(x: rect.topLeft.x * imageSize.width, y: rect.topLeft.y * imageSize.height)
            let topRight = CGPoint(x: rect.topRight.x * imageSize.width, y: rect.topRight.y * imageSize.height)
            let bottomLeft = CGPoint(x: rect.bottomLeft.x * imageSize.width, y: rect.bottomLeft.y * imageSize.height)
            let bottomRight = CGPoint(x: rect.bottomRight.x * imageSize.width, y: rect.bottomRight.y * imageSize.height)

            guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
                completion(nil)
                return
            }

            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
            filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
            filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
            filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

            guard let output = filter.outputImage else {
                completion(nil)
                return
            }

            let context = CIContext()
            guard let cgResult = context.createCGImage(output, from: output.extent) else {
                completion(nil)
                return
            }

            let resultImage = NSImage(cgImage: cgResult, size: NSSize(width: cgResult.width, height: cgResult.height))
            completion(resultImage)
        }

        request.maximumObservations = 1
        request.minimumConfidence = 0.5

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    /// Async wrapper
    static func autoCrop(image: NSImage) async -> NSImage? {
        await withCheckedContinuation { continuation in
            autoCrop(image: image) { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Helpers

    private static func ciImage(from nsImage: NSImage) -> CIImage? {
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return CIImage(bitmapImageRep: bitmap)
    }
}
