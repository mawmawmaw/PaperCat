import Foundation

/// HP LEDM (Low-End Device Manager) scanning protocol over USB
class LEDMProtocol {
    private let transport: USBTransport

    static let scanNamespace = "http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19"

    init(transport: USBTransport) {
        self.transport = transport
    }

    /// Discovered paths and protocol info
    var jobsPath: String = "/Scan/Jobs"
    private(set) var discoveredProtocol: String = "unknown"

    // MARK: - Endpoint Discovery

    struct ProbeResult {
        let path: String
        let status: Int
        let bodyPreview: String
        let contentType: String  // detected from XML content, not HTTP header
    }

    /// Probe the device to map out its HTTP endpoints.
    /// The M125a's USB HTTP server returns responses sequentially from an internal queue,
    /// so we identify responses by their XML content, not by which URL we requested.
    func discoverEndpoints() throws -> [ProbeResult] {
        // These are the paths we know HP devices use. We'll probe each one,
        // but identify the response by its XML root element / namespace.
        let pathsToProbe = [
            "/Scan/Capabilities",
            "/Scan/Status",
            "/Scan/Jobs",
            "/eSCL/ScannerCapabilities",
            "/eSCL/ScannerStatus",
            "/DevMgmt/DiscoveryTree.xml",
            "/DevMgmt/ProductStatusDyn.xml",
            "/DevMgmt/ProductConfigDyn.xml",
            "/DevMgmt/ProductUsageDyn.xml",
            "/hp/device/info",
            "/EventMgmt/EventTable",
        ]

        var results: [ProbeResult] = []

        for path in pathsToProbe {
            let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
            do {
                let response = try transport.sendHTTPRequest(request)
                let body = response.bodyString ?? ""
                let preview = String(body.prefix(300))
                let contentType = identifyContent(body)
                results.append(ProbeResult(path: path, status: response.statusCode, bodyPreview: preview, contentType: contentType))

                // Map the URL to the correct content type
                // Since the device serves responses from a queue, we track
                // which URL actually returned which content
                if contentType == "ScannerCapabilities" {
                    // Store the capabilities XML for later use
                    cachedCapabilitiesXML = body
                }
                if contentType == "DiscoveryTree" {
                    // The DiscoveryTree tells us the real URL paths
                    parseDiscoveryTree(body)
                }
                if contentType == "ScannerStatus" {
                    cachedStatusXML = body
                }
            } catch {
                results.append(ProbeResult(path: path, status: -1, bodyPreview: "ERROR: \(error.localizedDescription)", contentType: "error"))
            }
        }

        return results
    }

    func identifyContentPublic(_ body: String) -> String { identifyContent(body) }

    /// Identify what a response actually contains by looking at XML content
    private func identifyContent(_ body: String) -> String {
        if body.contains("ScannerCapabilities") { return "ScannerCapabilities" }
        if body.contains("ScannerStatus") || body.contains("ScannerState") { return "ScannerStatus" }
        if body.contains("DiscoveryTree") { return "DiscoveryTree" }
        if body.contains("ProductStatusDyn") { return "ProductStatusDyn" }
        if body.contains("ProductConfigDyn") { return "ProductConfigDyn" }
        if body.contains("ProductUsageDyn") { return "ProductUsageDyn" }
        if body.contains("ScanJob") { return "ScanJobs" }
        if body.contains("<html") || body.contains("<HTML") { return "HTML" }
        if body.isEmpty { return "empty" }
        return "unknown"
    }

    /// Parse DiscoveryTree to find the real API paths
    private func parseDiscoveryTree(_ xml: String) {
        // Look for scan-related resource URIs in the discovery tree
        // e.g. <dd:ResourceURI>/Scan/Jobs</dd:ResourceURI>
        let uris = extractValues(from: xml, tag: "ResourceURI")
        for uri in uris {
            if uri.lowercased().contains("scan") && uri.lowercased().contains("job") {
                jobsPath = uri
            }
        }
        discoveredProtocol = "LEDM"
    }

    /// Cached XML from probing
    var cachedCapabilitiesXML: String?
    var cachedStatusXML: String?

    // MARK: - Capabilities

    struct ScanCapabilities {
        var supportedResolutions: [Int] = []
        var supportedColorSpaces: [String] = []
        var supportedFormats: [String] = []
        var minWidth: Int = 0
        var maxWidth: Int = 0
        var minHeight: Int = 0
        var maxHeight: Int = 0
        var rawXML: String = ""
    }

    func getCapabilities() throws -> ScanCapabilities {
        // If we already have capabilities from probing, use that
        if let xml = cachedCapabilitiesXML, let data = xml.data(using: .utf8) {
            return parseCapabilities(data)
        }

        // Otherwise, make a direct request (may get wrong response due to device queueing)
        let request = "GET /Scan/Capabilities HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let response = try transport.sendHTTPRequest(request)

        // Check if response actually contains capabilities regardless of status code
        if let body = response.bodyString, body.contains("ScannerCapabilities") {
            return parseCapabilities(response.body)
        }

        throw LEDMError.requestFailed(status: response.statusCode, path: "/Scan/Capabilities")
    }

    private func parseCapabilities(_ data: Data) -> ScanCapabilities {
        var caps = ScanCapabilities()

        guard let xml = String(data: data, encoding: .utf8) else { return caps }
        caps.rawXML = xml

        // eSCL uses tags like scc:XResolution, pwg:DocumentFormat, etc.
        // Try multiple tag names used across LEDM and eSCL schemas

        // Resolutions — eSCL uses XResolution/YResolution or DiscreteResolution
        var resolutions: [Int] = []
        resolutions.append(contentsOf: extractValues(from: xml, tag: "XResolution").compactMap { Int($0) })
        resolutions.append(contentsOf: extractValues(from: xml, tag: "Resolution").compactMap { Int($0) })
        caps.supportedResolutions = Array(Set(resolutions)).sorted()

        // Color spaces — eSCL uses ColorSpace or Color tags
        var colors = extractValues(from: xml, tag: "ColorSpace")
        colors.append(contentsOf: extractValues(from: xml, tag: "Color"))
        colors.append(contentsOf: extractValues(from: xml, tag: "ColorReference"))
        caps.supportedColorSpaces = Array(Set(colors))

        // Formats — eSCL uses DocumentFormat (e.g. "image/jpeg")
        var formats = extractValues(from: xml, tag: "Format")
        formats.append(contentsOf: extractValues(from: xml, tag: "DocumentFormat"))
        caps.supportedFormats = Array(Set(formats))

        // Scan area dimensions
        if let maxW = extractValue(from: xml, tag: "MaxWidth") { caps.maxWidth = Int(maxW) ?? 0 }
        if let maxH = extractValue(from: xml, tag: "MaxHeight") { caps.maxHeight = Int(maxH) ?? 0 }
        if let minW = extractValue(from: xml, tag: "MinWidth") { caps.minWidth = Int(minW) ?? 0 }
        if let minH = extractValue(from: xml, tag: "MinHeight") { caps.minHeight = Int(minH) ?? 0 }

        return caps
    }

    // MARK: - Scan Job

    enum JobState: String {
        case processing = "Processing"
        case readyToUpload = "ReadyToUpload"
        case completed = "Completed"
        case canceled = "Canceled"
        case unknown = "Unknown"
    }

    /// Create a scan job by trying multiple endpoints and XML formats.
    /// The M125a has partial eSCL (read-only) so we try HP's LEDM format too.
    func createScanJob(
        resolution: Int,
        colorMode: String,
        widthIn300ths: Int,
        heightIn300ths: Int,
        format: String = "image/jpeg"
    ) throws -> String {
        // Map colorMode to LEDM color space
        let ledmColorSpace: String
        switch colorMode {
        case "RGB24": ledmColorSpace = "Color"
        case "Grayscale8": ledmColorSpace = "Gray"
        case "BlackAndWhite1": ledmColorSpace = "Gray"
        default: ledmColorSpace = "Gray"
        }

        let ledmBitDepth = colorMode == "BlackAndWhite1" ? 1 : 8

        // Try multiple endpoint + XML format combinations
        let attempts: [(path: String, xml: String)] = [
            // HP LEDM format (most likely for M125a USB)
            ("/Scan/Jobs", buildLEDMScanXML(resolution: resolution, colorSpace: ledmColorSpace, bitDepth: ledmBitDepth, width: widthIn300ths, height: heightIn300ths, format: format)),
            // eSCL format
            ("/eSCL/ScanJobs", buildESCLScanXML(resolution: resolution, colorMode: colorMode, width: widthIn300ths, height: heightIn300ths, format: format)),
            // LEDM with alternate namespace
            ("/Scan/Jobs", buildLEDMScanXMLv2(resolution: resolution, colorSpace: ledmColorSpace, bitDepth: ledmBitDepth, width: widthIn300ths, height: heightIn300ths)),
        ]

        // Try POST, then PUT for each path/XML combo
        let methods = ["POST", "PUT"]

        for (path, xmlBody) in attempts {
            for method in methods {
            let request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/xml\r\nContent-Length: \(xmlBody.utf8.count)\r\n\r\n\(xmlBody)"

            logToFile("Trying scan job: \(method) \(path)")
            logToFile("XML:\n\(xmlBody)")

            do {
                let response = try transport.sendHTTPRequest(request)
                logToFile("  → status=\(response.statusCode), headers=\(response.headers)")
                logToFile("  → body: \(response.bodyString?.prefix(300) ?? "nil")")

                if response.statusCode == 201 || response.statusCode == 200 {
                    if let location = response.headers["location"] {
                        logToFile("  ✓ Job created at: \(location)")
                        return location
                    }
                    if let body = response.bodyString,
                       let uri = extractValue(from: body, tag: "JobUri") ?? extractValue(from: body, tag: "ResourceURI") ?? extractValue(from: body, tag: "JobUrl") {
                        logToFile("  ✓ Job URI from body: \(uri)")
                        return uri
                    }
                    logToFile("  ✓ Job accepted (no location), using \(path)/1")
                    return "\(path)/1"
                }

                if response.statusCode == 404 {
                    logToFile("  → 404, trying next...")
                    continue
                }

                // Any other status — log and try next
                logToFile("  → unexpected status \(response.statusCode)")
            } catch {
                logToFile("  → error: \(error)")
            }
            } // end methods loop
        }

        throw LEDMError.jobCreationFailed(status: 404, detail: "All scan job endpoints returned 404")
    }

    // MARK: - Scan XML Builders

    private func buildLEDMScanXML(resolution: Int, colorSpace: String, bitDepth: Int, width: Int, height: Int, format: String) -> String {
        let ns = "http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19"
        let fmt = format == "image/jpeg" ? "Jpeg" : "Pdf"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanJob xmlns:scan="\(ns)">
        <scan:XResolution>\(resolution)</scan:XResolution>
        <scan:YResolution>\(resolution)</scan:YResolution>
        <scan:XStart>0</scan:XStart>
        <scan:YStart>0</scan:YStart>
        <scan:Width>\(width)</scan:Width>
        <scan:Height>\(height)</scan:Height>
        <scan:InputSource>Platen</scan:InputSource>
        <scan:ColorSpace>\(colorSpace)</scan:ColorSpace>
        <scan:BitDepth>\(bitDepth)</scan:BitDepth>
        <scan:Format>\(fmt)</scan:Format>
        <scan:CompressionQFactor>25</scan:CompressionQFactor>
        </scan:ScanJob>
        """
    }

    private func buildESCLScanXML(resolution: Int, colorMode: String, width: Int, height: Int, format: String) -> String {
        let ns = "http://schemas.hp.com/imaging/escl/2011/05/03"
        let pwgNS = "http://www.pwg.org/schemas/2010/12/sm"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="\(ns)" xmlns:pwg="\(pwgNS)">
        <pwg:Version>1.0</pwg:Version>
        <pwg:ScanRegions><pwg:ScanRegion>
        <pwg:XOffset>0</pwg:XOffset>
        <pwg:YOffset>0</pwg:YOffset>
        <pwg:Width>\(width)</pwg:Width>
        <pwg:Height>\(height)</pwg:Height>
        <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
        </pwg:ScanRegion></pwg:ScanRegions>
        <pwg:InputSource>Platen</pwg:InputSource>
        <scan:XResolution>\(resolution)</scan:XResolution>
        <scan:YResolution>\(resolution)</scan:YResolution>
        <scan:ColorMode>\(colorMode)</scan:ColorMode>
        <pwg:DocumentFormat>\(format)</pwg:DocumentFormat>
        </scan:ScanSettings>
        """
    }

    private func buildLEDMScanXMLv2(resolution: Int, colorSpace: String, bitDepth: Int, width: Int, height: Int) -> String {
        // Alternate LEDM format used by some HP devices
        let ns = "http://www.hp.com/schemas/imaging/con/ledm/scan/2009/10/09"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ScanJob xmlns="\(ns)">
        <XResolution>\(resolution)</XResolution>
        <YResolution>\(resolution)</YResolution>
        <XStart>0</XStart>
        <YStart>0</YStart>
        <Width>\(width)</Width>
        <Height>\(height)</Height>
        <InputSource>Platen</InputSource>
        <ScanType>Document</ScanType>
        <ColorSpace>\(colorSpace)</ColorSpace>
        <BitDepth>\(bitDepth)</BitDepth>
        <Format>Jpeg</Format>
        </ScanJob>
        """
    }

    private func logToFile(_ message: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PaperCat.log")
        let line = "[\(Date())] [LEDM] \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }

    /// Poll the scan job status
    func getJobStatus(jobURL: String) throws -> JobState {
        let request = """
        GET \(jobURL) HTTP/1.1\r
        Host: localhost\r
        \r

        """

        let response = try transport.sendHTTPRequest(request)
        guard response.statusCode == 200 else {
            return .unknown
        }

        guard let xml = response.bodyString else { return .unknown }

        if let state = extractValue(from: xml, tag: "JobState") ??
                       extractValue(from: xml, tag: "scan:JobState") ??
                       extractValue(from: xml, tag: "j:JobState") {
            return JobState(rawValue: state) ?? .unknown
        }

        // If we can't find JobState but got 200, check for PageState
        if let pageState = extractValue(from: xml, tag: "PageState") {
            if pageState == "ReadyToUpload" { return .readyToUpload }
        }

        return .unknown
    }

    /// Download the scanned image data via eSCL
    func downloadPage(jobURL: String) throws -> Data {
        // eSCL uses /NextDocument to fetch the scanned page
        let pageURL = "\(jobURL)/NextDocument"

        let request = "GET \(pageURL) HTTP/1.1\r\nHost: localhost\r\n\r\n"

        logToFile("Downloading: GET \(pageURL)")
        let response = try transport.sendHTTPRequest(request, expectLargeBody: true)
        logToFile("Download response: status=\(response.statusCode), bodySize=\(response.body.count)")

        guard response.statusCode == 200 else {
            throw LEDMError.downloadFailed(status: response.statusCode)
        }

        // Verify this is actually image data, not an XML document from the queue
        if response.body.count > 10 {
            let header = Array(response.body.prefix(4))
            // JPEG starts with FF D8 FF
            if header.count >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF {
                logToFile("Got JPEG data: \(response.body.count) bytes")
                return response.body
            }
            // PDF starts with %PDF
            if header.count >= 4 && header[0] == 0x25 && header[1] == 0x50 && header[2] == 0x44 && header[3] == 0x46 {
                logToFile("Got PDF data: \(response.body.count) bytes")
                return response.body
            }
        }

        // If it's not image data, it might be a queued XML response
        logToFile("WARNING: Downloaded data doesn't look like image. First 100 bytes: \(String(data: response.body.prefix(100), encoding: .utf8) ?? "non-text")")
        throw LEDMError.downloadFailed(status: -1)
    }

    /// Cancel a scan job
    func cancelJob(jobURL: String) throws {
        let xmlBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:JobState xmlns:scan="\(Self.scanNamespace)">Canceled</scan:JobState>
        """

        let request = """
        PUT \(jobURL) HTTP/1.1\r
        Host: localhost\r
        Content-Type: text/xml\r
        Content-Length: \(xmlBody.utf8.count)\r
        \r
        \(xmlBody)
        """

        _ = try? transport.sendHTTPRequest(request)
    }

    // MARK: - High-level scan

    struct ScanResult {
        let imageData: Data
        let format: String
    }

    /// Perform a complete eSCL scan: create job → poll → download
    func performScan(
        resolution: Int,
        colorSpace: String,       // "Color", "Gray", or "BlackAndWhite"
        paperWidthInches: Double,
        paperHeightInches: Double,
        format: String = "image/jpeg",
        progressCallback: ((String) -> Void)? = nil
    ) throws -> ScanResult {
        // Convert paper size to 1/300" units (the M125a's coordinate system)
        let widthIn300ths = Int(paperWidthInches * 300.0)
        let heightIn300ths = Int(paperHeightInches * 300.0)

        // Map color space to eSCL ColorMode (ColorReference values from capabilities)
        let colorMode: String
        switch colorSpace {
        case "Color": colorMode = "RGB24"
        case "Gray": colorMode = "Grayscale8"
        case "BlackAndWhite": colorMode = "BlackAndWhite1"
        default: colorMode = "Grayscale8"
        }

        // For B&W and Grayscale, use PDF since JPEG isn't supported for those
        let actualFormat: String
        if colorMode == "RGB24" {
            actualFormat = format  // image/jpeg works for color
        } else {
            actualFormat = "application/pdf"  // safer for grayscale/BW
        }

        progressCallback?("Creating scan job...")

        let jobURL = try createScanJob(
            resolution: resolution,
            colorMode: colorMode,
            widthIn300ths: widthIn300ths,
            heightIn300ths: heightIn300ths,
            format: actualFormat
        )

        progressCallback?("Scanning...")
        logToFile("Scan job created: \(jobURL)")

        // Poll for completion
        var attempts = 0
        let maxAttempts = 120  // 2 minutes at 1s intervals
        while attempts < maxAttempts {
            Thread.sleep(forTimeInterval: 1.0)
            attempts += 1

            // Try to get job status
            let status = try getJobStatus(jobURL: jobURL)
            logToFile("Job status (attempt \(attempts)): \(status)")

            switch status {
            case .readyToUpload, .completed:
                progressCallback?("Downloading image...")
                let imageData = try downloadPage(jobURL: jobURL)
                return ScanResult(imageData: imageData, format: actualFormat)

            case .processing:
                continue

            case .canceled:
                throw LEDMError.jobCanceled

            case .unknown:
                // The response might be from the queue, not the actual job status.
                // After a reasonable wait, try downloading anyway.
                if attempts > 5 {
                    progressCallback?("Downloading image...")
                    do {
                        let imageData = try downloadPage(jobURL: jobURL)
                        if !imageData.isEmpty {
                            return ScanResult(imageData: imageData, format: actualFormat)
                        }
                    } catch {
                        logToFile("Download attempt failed: \(error)")
                    }
                }
            }
        }

        throw LEDMError.timeout
    }

    // MARK: - XML Helpers

    func extractValue(from xml: String, tag: String) -> String? {
        // Match <tag>value</tag> or <anyprefix:tag>value</anyprefix:tag>
        // The prefix pattern handles scc:, pwg:, scan:, dd:, ledm:, etc.
        let pattern = "<(?:[a-zA-Z0-9]+:)?\(tag)>(.*?)</(?:[a-zA-Z0-9]+:)?\(tag)>"

        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           let range = Range(match.range(at: 1), in: xml) {
            return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func extractValues(from xml: String, tag: String) -> [String] {
        let pattern = "<(?:[a-zA-Z0-9]+:)?\(tag)>(.*?)</(?:[a-zA-Z0-9]+:)?\(tag)>"
        var results: [String] = []

        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                if let range = Range(match.range(at: 1), in: xml) {
                    let value = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        results.append(value)
                    }
                }
            }
        }
        return results
    }
}

// MARK: - Errors

enum LEDMError: LocalizedError {
    case requestFailed(status: Int, path: String)
    case jobCreationFailed(status: Int, detail: String)
    case noLocationHeader
    case downloadFailed(status: Int)
    case jobCanceled
    case timeout

    var errorDescription: String? {
        switch self {
        case .requestFailed(let s, let p): return "Request to \(p) failed with status \(s)"
        case .jobCreationFailed(let s, let d): return "Scan job creation failed (\(s)): \(d)"
        case .noLocationHeader: return "No Location header in job creation response"
        case .downloadFailed(let s): return "Image download failed with status \(s)"
        case .jobCanceled: return "Scan job was canceled"
        case .timeout: return "Scan timed out waiting for image data"
        }
    }
}
