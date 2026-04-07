import Foundation

enum ScanColorMode: String, CaseIterable, Identifiable {
    case blackAndWhite = "Black & White"
    case grayscale = "Grayscale"
    case color = "Color"

    var id: String { rawValue }
}

enum ScanResolution: Int, CaseIterable, Identifiable {
    case dpi100 = 100
    case dpi300 = 300
    case dpi600 = 600

    var id: Int { rawValue }
    var label: String { "\(rawValue) DPI" }
}

enum PaperSize: String, CaseIterable, Identifiable {
    case letter = "Letter"
    case a4 = "A4"
    case legal = "Legal"

    var id: String { rawValue }

    /// Width in inches
    var widthInches: Double {
        switch self {
        case .letter: return 8.5
        case .a4: return 8.27
        case .legal: return 8.5
        }
    }

    /// Height in inches
    var heightInches: Double {
        switch self {
        case .letter: return 11.0
        case .a4: return 11.69
        case .legal: return 14.0
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF"
    case png = "PNG"
    case jpeg = "JPEG"
    case tiff = "TIFF"

    var id: String { rawValue }

    var fileExtension: String { rawValue.lowercased() }

    var utType: String {
        switch self {
        case .pdf: return "com.adobe.pdf"
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .tiff: return "public.tiff"
        }
    }
}

struct ScanSettings {
    var colorMode: ScanColorMode = .grayscale
    var resolution: ScanResolution = .dpi300
    var paperSize: PaperSize = .letter
    var exportFormat: ExportFormat = .pdf
}
