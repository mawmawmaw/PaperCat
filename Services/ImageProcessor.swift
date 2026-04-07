import AppKit
import CoreImage

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

        var output = ciImage
        if brightness != 0 || contrast != 1.0 {
            guard let colorFilter = CIFilter(name: "CIColorControls") else { return nil }
            colorFilter.setValue(output, forKey: kCIInputImageKey)
            colorFilter.setValue(brightness, forKey: kCIInputBrightnessKey)
            colorFilter.setValue(contrast, forKey: kCIInputContrastKey)
            guard let result = colorFilter.outputImage else { return nil }
            output = result
        }

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

    // MARK: - Manual Crop

    /// Crop an image to the given rect (in image pixel coordinates).
    static func crop(image: NSImage, to rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Clamp rect to image bounds
        let imgRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clampedRect = rect.intersection(imgRect)
        guard !clampedRect.isEmpty, clampedRect.width > 1, clampedRect.height > 1 else { return nil }

        guard let cropped = cgImage.cropping(to: clampedRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    // MARK: - Helpers

    private static func ciImage(from nsImage: NSImage) -> CIImage? {
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return CIImage(bitmapImageRep: bitmap)
    }
}
