import AppKit
import CLibUSB
import Foundation

@MainActor
class ScannerManager: NSObject, ObservableObject {
    @Published var scannerIsReady = false
    @Published var isScanning = false
    @Published var statusMessage = "Looking for scanner..."
    @Published var lastScannedImage: NSImage?
    @Published var errorMessage: String?

    private var transport: USBTransport?
    private var ledm: LEDMProtocol?
    private var pollTimer: Timer?
    private let usbQueue = DispatchQueue(label: "com.hpscanner.usb", qos: .userInitiated)
    private var isAttemptingConnection = false

    override init() {
        super.init()
        startPolling()
    }

    func startPolling() {
        attemptConnection()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkConnection() }
        }
    }

    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    private func attemptConnection() {
        guard !isAttemptingConnection else { return }
        isAttemptingConnection = true
        if errorMessage == nil { statusMessage = "Searching for HP LaserJet Pro MFP M125a..." }

        usbQueue.async { [weak self] in
            do {
                let t = try USBTransport()
                try t.findAndConnect()
                Self.log("USB connected!")

                let proto = LEDMProtocol(transport: t)

                // Get capabilities from Interface 2 (HTTP)
                let capReq = "GET /eSCL/ScannerCapabilities HTTP/1.1\r\nHost: localhost\r\n\r\n"
                if let resp = try? t.sendHTTPRequest(capReq), let body = resp.bodyString, body.contains("ScannerCapabilities") {
                    proto.cachedCapabilitiesXML = body
                } else {
                    for url in ["/DevMgmt/ProductStatusDyn.xml", "/DevMgmt/ProductConfigDyn.xml",
                                "/DevMgmt/ProductUsageDyn.xml", "/eSCL/ScannerCapabilities", "/eSCL/ScannerStatus"] {
                        if let r = try? t.sendHTTPRequest("GET \(url) HTTP/1.1\r\nHost: localhost\r\n\r\n"),
                           let b = r.bodyString, b.contains("ScannerCapabilities") {
                            proto.cachedCapabilitiesXML = b; break
                        }
                    }
                }

                let caps = try proto.getCapabilities()
                Self.log("Ready: resolutions=\(caps.supportedResolutions), SOAP=\(t.soapInterfaceClaimed)")

                Task { @MainActor in
                    guard let self else { return }
                    self.isAttemptingConnection = false
                    self.transport = t
                    self.ledm = proto
                    self.scannerIsReady = true
                    self.errorMessage = nil
                    self.statusMessage = "Ready — \(caps.supportedResolutions.map{"\($0)"}.joined(separator: ", ")) DPI"
                }
            } catch {
                Self.log("Connection failed: \(error)")
                Task { @MainActor in
                    guard let self else { return }
                    self.isAttemptingConnection = false
                    self.scannerIsReady = false
                    if case USBError.noDeviceFound = error {
                        self.statusMessage = "Scanner not found (USB)"
                        self.errorMessage = nil
                    } else {
                        self.statusMessage = "Error: \(error.localizedDescription)"
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func checkConnection() {
        if scannerIsReady {
            guard let t = transport, t.isConnected else {
                transport?.disconnect(); transport = nil; ledm = nil
                scannerIsReady = false; statusMessage = "Scanner disconnected"
                return
            }
        } else { attemptConnection() }
    }

    // MARK: - Scanning via SOAP/WSD on Interface 0

    func scan(
        resolution: ScanResolution,
        colorMode: ScanColorMode,
        paperSize: PaperSize,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        guard let transport = self.transport, scannerIsReady, transport.soapInterfaceClaimed else {
            completion(.failure(ScannerError.notReady))
            return
        }
        guard !isScanning else {
            completion(.failure(ScannerError.alreadyScanning))
            return
        }

        isScanning = true
        errorMessage = nil

        usbQueue.async { [weak self] in
            do {
                Self.log("Scan request: resolution=\(resolution.rawValue), color=\(colorMode.rawValue), paper=\(paperSize.rawValue)")
                Self.log("Parity mode active: using CreateScanJob RGB24 @ 300 DPI (Letter)")

                Task { @MainActor in self?.statusMessage = "Preparing scan session..." }
                try transport.prepareInteractiveSOAPSession()

                Task { @MainActor in self?.statusMessage = "Querying scanner..." }
                let getElementsEnvelope = Self.soapEnvelope("<wscn:GetScannerElements></wscn:GetScannerElements>")
                try transport.sendSOAPEnvelope(path: "/", envelope: getElementsEnvelope)
                let getElementsResponse = try transport.readSOAPResponseBuffer(
                    maxBytes: 65_536,
                    maxReads: 30,
                    transferTimeout: 3_000,
                    emptyReadBreak: 8
                )
                Self.log("GetScannerElements response: \(getElementsResponse.count) bytes")
                Self.log("GetScannerElements preview: \(Self.previewText(getElementsResponse))")

                Task { @MainActor in self?.statusMessage = "Creating scan job..." }
                let createEnvelope = Self.soapEnvelope(Self.parityCreateScanJobBody())
                try transport.sendSOAPEnvelope(path: "/", envelope: createEnvelope)
                var createResponse = try transport.readSOAPResponseBuffer(
                    maxBytes: 131_072,
                    maxReads: 30,
                    transferTimeout: 3_000,
                    emptyReadBreak: 8
                )

                Self.log("CreateScanJob response: \(createResponse.count) bytes")
                Self.log("CreateScanJob preview: \(Self.previewText(createResponse))")

                var jobId = Self.extractJobID(from: createResponse)
                if let immediateJobId = jobId {
                    Self.log("CreateScanJob immediate JobId: \(immediateJobId)")
                }

                if jobId == nil || jobId == "1" {
                    Task { @MainActor in self?.statusMessage = "Waiting for scan job..." }
                    let delayedData = try transport.readSOAPForDuration(
                        maxBytes: 524_288,
                        duration: 30.0,
                        transferTimeout: 1_000,
                        idleSleep: 0.2
                    )

                    if !delayedData.isEmpty {
                        createResponse.append(delayedData)
                        Self.log("Delayed SOAP data: \(delayedData.count) bytes")
                        Self.log("Delayed SOAP preview: \(Self.previewText(delayedData))")
                    }

                    if let delayedJobId = Self.extractJobID(from: createResponse) {
                        jobId = delayedJobId
                        Self.log("Using delayed JobId: \(delayedJobId)")
                    }
                }

                if jobId == nil {
                    jobId = "1"
                    Self.log("No JobId found; falling back to JobId=1")
                }

                guard let finalJobId = jobId else {
                    throw ScannerError.scanFailed(detail: "Could not determine scan JobId")
                }

                Task { @MainActor in self?.statusMessage = "Scanning and retrieving image..." }

                var extraction: DIMEImageExtractor.ExtractionResult?
                var lastRetrieveResponse = Data()
                let deadline = Date().addingTimeInterval(180.0)
                var retrieveAttempt = 0

                while Date() < deadline {
                    retrieveAttempt += 1

                    let retrieveEnvelope = Self.soapEnvelope(Self.retrieveImageBody(jobId: finalJobId))
                    try transport.sendSOAPEnvelope(path: "/", envelope: retrieveEnvelope)
                    Self.log("RetrieveImage attempt \(retrieveAttempt) sent (JobId=\(finalJobId))")

                    let retrieveResponse = try transport.readSOAPImageData(
                        maxBytes: 10_000_000,
                        duration: 25.0,
                        transferTimeout: 2_000,
                        emptyReadBreak: 30
                    )

                    if retrieveResponse.isEmpty {
                        Self.log("RetrieveImage attempt \(retrieveAttempt): no data")
                    } else {
                        lastRetrieveResponse = retrieveResponse
                        Self.log("RetrieveImage attempt \(retrieveAttempt): \(retrieveResponse.count) bytes")
                        Self.log("RetrieveImage preview: \(Self.previewText(retrieveResponse))")

                        if let parsed = try? DIMEImageExtractor.extract(from: retrieveResponse) {
                            extraction = parsed
                            break
                        }
                    }

                    Thread.sleep(forTimeInterval: 2.0)
                }

                guard let extraction else {
                    if !lastRetrieveResponse.isEmpty {
                        let failedRawPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("papercat_scan_raw.bin")
                        try? lastRetrieveResponse.write(to: failedRawPath)
                        Self.log("Saved last retrieve response to \(failedRawPath.path)")
                    }
                    throw ScannerError.scanFailed(detail: "RetrieveImage timed out before image payload was available")
                }

                let imageData = lastRetrieveResponse

                let rawPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("papercat_scan_raw.bin")
                try? imageData.write(to: rawPath)
                Self.log("Saved raw data to \(rawPath.path)")

                Self.log("Extracted \(extraction.mimeType): payload=\(extraction.payloadData.count) jpeg=\(extraction.jpegData.count)")

                let payloadPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("papercat_scan_raw_jpeg.bin")
                try? extraction.payloadData.write(to: payloadPath)
                Self.log("Saved image payload to \(payloadPath.path)")

                let normalizedData = Self.reencodeJPEG(extraction.jpegData)
                if normalizedData.count != extraction.jpegData.count {
                    Self.log("Re-encoded JPEG for compatibility: \(extraction.jpegData.count) -> \(normalizedData.count)")
                }

                guard let image = NSImage(data: normalizedData) else {
                    throw ScannerError.imageLoadFailed
                }

                let savePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("papercat_scan_test.jpg")
                try? normalizedData.write(to: savePath)

                Task { @MainActor in
                    guard let self else { return }
                    self.lastScannedImage = image
                    self.isScanning = false
                    self.statusMessage = "Scan complete"
                    completion(.success(image))
                }
            } catch {
                Self.log("Scan failed: \(error)")
                Task { @MainActor in
                    guard let self else { return }
                    self.isScanning = false
                    self.statusMessage = "Scan failed"
                    self.errorMessage = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    func cleanup() { stopPolling(); transport?.disconnect() }

    nonisolated private static func reencodeJPEG(_ data: Data) -> Data {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let encoded = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            return data
        }
        return encoded
    }

    nonisolated private static func soapEnvelope(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://www.w3.org/2003/05/soap-envelope\" "
            + "xmlns:SOAP-ENC=\"http://www.w3.org/2003/05/soap-encoding\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
            + "xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" "
            + "xmlns:wscn=\"http://tempuri.org/wscn.xsd\">"
            + "<SOAP-ENV:Body>"
            + body
            + "</SOAP-ENV:Body></SOAP-ENV:Envelope>"
    }

    nonisolated private static func parityCreateScanJobBody() -> String {
        "<wscn:CreateScanJobRequest>"
            + "<ScanIdentifier></ScanIdentifier><ScanTicket><JobDescription></JobDescription>"
            + "<DocumentParameters><Format>jfif</Format><InputSource>Platen</InputSource>"
            + "<InputSize><InputMediaSize><Width>8500</Width><Height>11000</Height></InputMediaSize>"
            + "<DocumentSizeAutoDetect>false</DocumentSizeAutoDetect></InputSize>"
            + "<MediaSides><MediaFront>"
            + "<ScanRegion><ScanRegionXOffset>0</ScanRegionXOffset><ScanRegionYOffset>0</ScanRegionYOffset>"
            + "<ScanRegionWidth>8500</ScanRegionWidth><ScanRegionHeight>11000</ScanRegionHeight></ScanRegion>"
            + "<Resolution><Width>300</Width><Height>300</Height></Resolution>"
            + "<ColorProcessing>RGB24</ColorProcessing>"
            + "</MediaFront></MediaSides></DocumentParameters></ScanTicket>"
            + "</wscn:CreateScanJobRequest>"
    }

    nonisolated private static func retrieveImageBody(jobId: String) -> String {
        "<wscn:RetrieveImageRequest>"
            + "<JobId>\(jobId)</JobId><JobToken>wscn:job:\(jobId)</JobToken>"
            + "<DocumentDescription></DocumentDescription>"
            + "</wscn:RetrieveImageRequest>"
    }

    nonisolated private static func extractJobID(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return USBTransport.extractXMLValue(from: text, tag: "JobId")
    }

    nonisolated private static func previewText(_ data: Data, maxChars: Int = 240) -> String {
        guard !data.isEmpty else { return "(empty)" }
        let snippetData = data.prefix(2_000)
        let text = String(data: snippetData, encoding: .utf8) ?? String(decoding: snippetData, as: UTF8.self)
        let compact = text
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return String(compact.prefix(maxChars))
    }

    nonisolated private static func log(_ message: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PaperCat.log")
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let h = try? FileHandle(forWritingTo: logPath) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
            } else { try? data.write(to: logPath) }
        }
    }
}

enum ScannerError: LocalizedError {
    case notReady
    case alreadyScanning
    case imageLoadFailed
    case scanFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "Scanner not ready. Connect HP LaserJet Pro MFP M125a via USB."
        case .alreadyScanning: return "A scan is already in progress."
        case .imageLoadFailed: return "Failed to decode scanned image."
        case .scanFailed(let d): return "Scan failed: \(d)"
        }
    }
}
