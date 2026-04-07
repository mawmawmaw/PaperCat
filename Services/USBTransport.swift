import Foundation
import CLibUSB

/// Low-level USB communication with HP printer via libusb
final class USBTransport: @unchecked Sendable {
    static let hpVendorID: UInt16 = 0x03f0
    static let m125aProductID: UInt16 = 0x222a

    static let targetInterfaceClass: UInt8 = 0xFF
    static let targetInterfaceSubClass: UInt8 = 0x04
    static let targetInterfaceProtocol: UInt8 = 0x01

    private var context: OpaquePointer?
    private(set) var deviceHandle: OpaquePointer?
    private var interfaceNumber: Int32 = -1
    private(set) var endpointIn: UInt8 = 0
    private(set) var endpointOut: UInt8 = 0
    private var kernelDriverDetached = false
    private(set) var dot4Channel: DOT4Channel?
    var soapEndpointIn: UInt8 = 0
    var soapEndpointOut: UInt8 = 0
    var soapInterfaceClaimed = false

    private let commandTimeout: UInt32 = 10_000
    private let dataTimeout: UInt32 = 60_000

    var isConnected: Bool { deviceHandle != nil }

    init() throws {
        let rc = libusb_init(&context)
        guard rc == 0 else { throw USBError.initFailed(code: rc) }
    }

    deinit {
        disconnect()
        if let ctx = context { libusb_exit(ctx) }
    }

    // MARK: - Connection

    func findAndConnect() throws {
        guard let ctx = context else { throw USBError.notInitialized }
        var deviceList: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &deviceList)
        guard count > 0, let list = deviceList else { throw USBError.noDeviceFound }
        defer { libusb_free_device_list(list, 1) }

        for i in 0..<count {
            guard let device = list[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &desc) == 0 else { continue }
            if desc.idVendor == Self.hpVendorID && desc.idProduct == Self.m125aProductID {
                try openDevice(device, descriptor: desc)
                return
            }
        }
        throw USBError.noDeviceFound
    }

    private func openDevice(_ device: OpaquePointer, descriptor: libusb_device_descriptor) throws {
        var handle: OpaquePointer?
        let rc = libusb_open(device, &handle)
        guard rc == 0, let h = handle else { throw USBError.openFailed(code: rc) }
        self.deviceHandle = h

        try findScanInterface(device: device, descriptor: descriptor)

        Self.logUSB("auto_detach_kernel_driver...")
        let autoDetachRC = libusb_set_auto_detach_kernel_driver(h, 1)
        Self.logUSB("  auto_detach result: \(autoDetachRC)")

        let activeRC = libusb_kernel_driver_active(h, interfaceNumber)
        if activeRC == 1 {
            let detachRC = libusb_detach_kernel_driver(h, interfaceNumber)
            if detachRC == 0 { kernelDriverDetached = true }
        }

        // Claim Interface 2 (HTTP document server)
        var claimed = false
        for attempt in 1...3 {
            let claimRC = libusb_claim_interface(h, interfaceNumber)
            Self.logUSB("claim_interface attempt \(attempt): \(claimRC)")
            if claimRC == 0 { claimed = true; break }
            if attempt < 3 { Thread.sleep(forTimeInterval: 1.0) }
        }
        guard claimed else {
            libusb_close(h); self.deviceHandle = nil
            throw USBError.claimFailed(code: -3)
        }

        flushReadBuffer()

        // Claim Interface 0 (SOAP/WSD scan command channel)
        let claim0RC = libusb_claim_interface(h, 0)
        Self.logUSB("Claim Interface 0: \(claim0RC)")
        if claim0RC == 0 {
            self.soapEndpointIn = 0x82
            self.soapEndpointOut = 0x02
            self.soapInterfaceClaimed = true
            Self.logUSB("Interface 0 ready (SOAP/WSD)")
        }
    }

    // MARK: - SOAP over Interface 0

    /// Prepare Interface 0 exactly like the working C flow:
    /// release/re-claim + DOT4 wake, then keep the same connection alive.
    func prepareInteractiveSOAPSession() throws {
        guard let h = deviceHandle else { throw USBError.notConnected }

        if !soapInterfaceClaimed {
            let claim0RC = libusb_claim_interface(h, 0)
            guard claim0RC == 0 else { throw USBError.claimFailed(code: claim0RC) }
            soapEndpointIn = 0x82
            soapEndpointOut = 0x02
            soapInterfaceClaimed = true
        }

        _ = libusb_release_interface(h, 0)
        Thread.sleep(forTimeInterval: 0.5)

        let reclaimRC = libusb_claim_interface(h, 0)
        guard reclaimRC == 0 else { throw USBError.claimFailed(code: reclaimRC) }

        var dot4Wake: [UInt8] = [0x00, 0x00, 0x00, 0x08, 0x01, 0x00, 0x00, 0x20]
        var transferred: Int32 = 0
        let wakeRC = libusb_bulk_transfer(h, soapEndpointOut, &dot4Wake, Int32(dot4Wake.count), &transferred, 1_000)
        guard wakeRC == 0 else { throw USBError.writeFailed(code: wakeRC) }

        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Send one SOAP HTTP POST on Interface 0 using gSOAP-like headers.
    func sendSOAPEnvelope(path: String = "/", envelope: String) throws {
        guard let h = deviceHandle, soapInterfaceClaimed else { throw USBError.notConnected }

        let request = "POST \(path) HTTP/1.1\r\nHost: localhost\r\nUser-Agent: gSOAP/2.7\r\nContent-Type: application/soap+xml; charset=utf-8\r\nContent-Length: \(envelope.utf8.count)\r\n\r\n\(envelope)"

        var reqBytes = Array(request.utf8)
        var transferred: Int32 = 0
        let writeRC = libusb_bulk_transfer(h, soapEndpointOut, &reqBytes, Int32(reqBytes.count), &transferred, 5_000)
        guard writeRC == 0 else { throw USBError.writeFailed(code: writeRC) }
    }

    /// C-style SOAP response read loop used for GetScannerElements/CreateScanJob.
    func readSOAPResponseBuffer(
        maxBytes: Int = 65_536,
        maxReads: Int = 30,
        transferTimeout: UInt32 = 3_000,
        emptyReadBreak: Int = 8
    ) throws -> Data {
        guard let h = deviceHandle, soapInterfaceClaimed else { throw USBError.notConnected }

        var result = Data()
        result.reserveCapacity(min(maxBytes, 65_536))

        var empty = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)

        for _ in 0..<maxReads {
            if result.count >= maxBytes { break }

            var received: Int32 = 0
            let toRead = min(buffer.count, maxBytes - result.count)
            let rc = libusb_bulk_transfer(h, soapEndpointIn, &buffer, Int32(toRead), &received, transferTimeout)

            if rc == 0 && received > 0 {
                result.append(contentsOf: buffer[0..<Int(received)])
                empty = 0
            } else {
                empty += 1
                if empty > emptyReadBreak && !result.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        return result
    }

    /// Read SOAP traffic for a fixed duration (used to catch delayed CreateScanJobResponse).
    func readSOAPForDuration(
        maxBytes: Int,
        duration: TimeInterval,
        transferTimeout: UInt32,
        idleSleep: TimeInterval = 0.2
    ) throws -> Data {
        guard let h = deviceHandle, soapInterfaceClaimed else { throw USBError.notConnected }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline {
            if result.count >= maxBytes { break }

            var received: Int32 = 0
            let toRead = min(buffer.count, maxBytes - result.count)
            let rc = libusb_bulk_transfer(h, soapEndpointIn, &buffer, Int32(toRead), &received, transferTimeout)

            if rc == 0 && received > 0 {
                result.append(contentsOf: buffer[0..<Int(received)])
            } else {
                Thread.sleep(forTimeInterval: idleSleep)
            }
        }

        return result
    }

    /// Read larger RetrieveImage responses (DIME/chunked payloads) like the C test loop.
    func readSOAPImageData(
        maxBytes: Int = 10_000_000,
        duration: TimeInterval = 60,
        transferTimeout: UInt32 = 2_000,
        emptyReadBreak: Int = 30
    ) throws -> Data {
        guard let h = deviceHandle, soapInterfaceClaimed else { throw USBError.notConnected }

        var result = Data()
        result.reserveCapacity(min(maxBytes, 1_048_576))

        let deadline = Date().addingTimeInterval(duration)
        var empty = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while Date() < deadline {
            if result.count >= maxBytes { break }

            var received: Int32 = 0
            let toRead = min(buffer.count, maxBytes - result.count)
            let rc = libusb_bulk_transfer(h, soapEndpointIn, &buffer, Int32(toRead), &received, transferTimeout)

            if rc == 0 && received > 0 {
                result.append(contentsOf: buffer[0..<Int(received)])
                empty = 0
            } else {
                empty += 1
                if empty > emptyReadBreak && !result.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        return result
    }

    /// Send a SOAP request on Interface 0 with retry logic.
    func sendSOAPRequest(path: String = "/Scan/Jobs", body: String, maxRetries: Int = 5) throws -> (statusCode: Int, body: String) {
        guard let h = deviceHandle, soapInterfaceClaimed else { throw USBError.notConnected }

        for attempt in 1...maxRetries {
            // Release and re-claim Interface 0
            libusb_release_interface(h, 0)
            Thread.sleep(forTimeInterval: 0.5)
            let rc = libusb_claim_interface(h, 0)
            guard rc == 0 else { continue }

            // Prime the gSOAP server with multiple rapid writes to different paths
            // This mimics the sequence that worked during our successful runs
            var xfer: Int32 = 0

            // Send DOT4 Init
            var dot4Init: [UInt8] = [0x00, 0x00, 0x00, 0x08, 0x01, 0x00, 0x00, 0x20]
            libusb_bulk_transfer(h, soapEndpointOut, &dot4Init, 8, &xfer, 1000)

            // Send a GET request (like the raw HTTP test in the successful run)
            var getReq = Array("GET /Scan/Jobs HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
            libusb_bulk_transfer(h, soapEndpointOut, &getReq, Int32(getReq.count), &xfer, 1000)

            // Read and discard any responses
            var discardBuf = [UInt8](repeating: 0, count: 65536)
            var discardXfer: Int32 = 0
            for _ in 0..<8 {
                libusb_bulk_transfer(h, soapEndpointIn, &discardBuf, Int32(discardBuf.count), &discardXfer, 500)
                if discardXfer == 0 { break }
            }

            // Now send DOT4 Init again (the successful runs had 2 DOT4 inits)
            libusb_bulk_transfer(h, soapEndpointOut, &dot4Init, 8, &xfer, 1000)
            Thread.sleep(forTimeInterval: 0.1)

            // POST request
            let httpReq = "POST \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            var reqBytes = Array(httpReq.utf8)
            libusb_bulk_transfer(h, soapEndpointOut, &reqBytes, Int32(reqBytes.count), &xfer, 5000)
            Self.logUSB("SOAP attempt \(attempt): sent \(xfer) bytes to \(path)")

            // Read response
            var resp = Data()
            var emptyReads = 0
            for _ in 1...30 {
                var buf = [UInt8](repeating: 0, count: 65536)
                var rXfer: Int32 = 0
                libusb_bulk_transfer(h, soapEndpointIn, &buf, Int32(buf.count), &rXfer, 5000)
                if rXfer > 0 {
                    resp.append(contentsOf: buf[0..<Int(rXfer)])
                    emptyReads = 0
                    if let s = String(data: resp, encoding: .utf8), s.contains("</SOAP-ENV:Envelope>") { break }
                } else {
                    emptyReads += 1
                    if emptyReads > 8 && resp.count > 0 { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            let respText = String(data: resp, encoding: .utf8) ?? ""
            let hasSuccess = respText.contains("CreateScanJobResponse") || respText.contains("201")
            Self.logUSB("  Attempt \(attempt) result: \(hasSuccess ? "SUCCESS" : "FAIL") (\(resp.count) bytes)")

            if hasSuccess || resp.count > 1000 {
                var statusCode = 0
                if respText.hasPrefix("HTTP/") {
                    let parts = respText.components(separatedBy: " ")
                    if parts.count >= 2 { statusCode = Int(parts[1]) ?? 0 }
                }
                return (statusCode, respText)
            }

            Self.logUSB("  Retrying...")
        }

        return (0, "All \(maxRetries) attempts failed")
    }

    /// Read bulk data from Interface 0 (for image retrieval)
    func readSOAPBulk(maxBytes: Int = 5_000_000, timeout: UInt32 = 30_000) throws -> Data {
        guard let h = deviceHandle else { throw USBError.notConnected }
        var result = Data()
        var emptyReads = 0
        for _ in 1...500 {
            var buf = [UInt8](repeating: 0, count: 65536)
            var xfer: Int32 = 0
            let rc = libusb_bulk_transfer(h, soapEndpointIn, &buf, Int32(buf.count), &xfer, timeout)
            if xfer > 0 {
                result.append(contentsOf: buf[0..<Int(xfer)])
                emptyReads = 0
                if result.count >= maxBytes { break }
            } else {
                emptyReads += 1
                if emptyReads > 15 && result.count > 0 { break }
                if rc == LIBUSB_ERROR_TIMEOUT.rawValue && result.count > 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return result
    }

    // MARK: - USB Helpers

    private func findScanInterface(device: OpaquePointer, descriptor: libusb_device_descriptor) throws {
        var config: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(device, &config) == 0, let cfg = config else {
            throw USBError.configFailed
        }
        defer { libusb_free_config_descriptor(cfg) }

        let interfaces = UnsafeBufferPointer(start: cfg.pointee.interface, count: Int(cfg.pointee.bNumInterfaces))
        for iface in interfaces {
            let altSettings = UnsafeBufferPointer(start: iface.altsetting, count: Int(iface.num_altsetting))
            for alt in altSettings {
                Self.logUSB("Interface \(alt.bInterfaceNumber): class=0x\(String(alt.bInterfaceClass, radix: 16)) subclass=0x\(String(alt.bInterfaceSubClass, radix: 16)) protocol=0x\(String(alt.bInterfaceProtocol, radix: 16)) endpoints=\(alt.bNumEndpoints)")

                if alt.bInterfaceClass == Self.targetInterfaceClass &&
                   alt.bInterfaceSubClass == Self.targetInterfaceSubClass &&
                   alt.bInterfaceProtocol == Self.targetInterfaceProtocol {
                    self.interfaceNumber = Int32(alt.bInterfaceNumber)
                    let endpoints = UnsafeBufferPointer(start: alt.endpoint, count: Int(alt.bNumEndpoints))
                    for ep in endpoints {
                        let tt = ep.bmAttributes & 0x03
                        guard tt == UInt8(LIBUSB_ENDPOINT_TRANSFER_TYPE_BULK.rawValue) else { continue }
                        if ep.bEndpointAddress & 0x80 != 0 { self.endpointIn = ep.bEndpointAddress }
                        else { self.endpointOut = ep.bEndpointAddress }
                    }
                    guard endpointIn != 0 && endpointOut != 0 else { throw USBError.endpointsNotFound }
                    return
                }
            }
        }
        throw USBError.interfaceNotFound
    }

    func flushReadBufferPublic() { flushReadBuffer() }

    private func flushReadBuffer() {
        guard let h = deviceHandle, endpointIn != 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var transferred: Int32 = 0
        for _ in 0..<20 {
            let rc = libusb_bulk_transfer(h, endpointIn, &buffer, Int32(buffer.count), &transferred, 200)
            if transferred == 0 || rc != 0 { break }
        }
    }

    func disconnect() {
        guard let h = deviceHandle else { return }
        if soapInterfaceClaimed { libusb_release_interface(h, 0) }
        libusb_release_interface(h, interfaceNumber)
        if kernelDriverDetached { libusb_attach_kernel_driver(h, interfaceNumber) }
        libusb_close(h)
        deviceHandle = nil
    }

    // MARK: - HTTP over USB (Interface 2)

    func sendHTTPRequest(_ request: String, expectLargeBody: Bool = false) throws -> HTTPResponse {
        guard let h = deviceHandle else { throw USBError.notConnected }

        var requestData = Array(request.utf8)
        var transferred: Int32 = 0
        let writeRC = libusb_bulk_transfer(h, endpointOut, &requestData, Int32(requestData.count), &transferred, commandTimeout)
        guard writeRC == 0 else { throw USBError.writeFailed(code: writeRC) }

        let timeout = expectLargeBody ? dataTimeout : commandTimeout
        let responseData = try readFullResponse(handle: h, timeout: timeout)
        return try HTTPResponse.parse(responseData)
    }

    private func readFullResponse(handle: OpaquePointer, timeout: UInt32) throws -> Data {
        var result = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var transferred: Int32 = 0

        // Read until we get data (device returns 0-3 empty reads before each response)
        var emptyCount = 0
        while result.isEmpty && emptyCount < 5 {
            let rc = libusb_bulk_transfer(handle, endpointIn, &buffer, Int32(bufferSize), &transferred, timeout)
            if rc == LIBUSB_ERROR_TIMEOUT.rawValue { throw USBError.readFailed(code: rc) }
            guard rc == 0 else { throw USBError.readFailed(code: rc) }
            if transferred > 0 { result.append(contentsOf: buffer[0..<Int(transferred)]) }
            else { emptyCount += 1; Thread.sleep(forTimeInterval: 0.02) }
        }
        guard !result.isEmpty else { return result }

        // Read remaining body if Content-Length is known
        if let headerEnd = result.range(of: Data("\r\n\r\n".utf8)) {
            let headerStr = String(data: result[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            if let contentLength = parseContentLength(headerStr) {
                let bodyStart = headerEnd.upperBound
                let bodyReceived = result.count - result.distance(from: result.startIndex, to: bodyStart)
                var remaining = contentLength - bodyReceived
                while remaining > 0 {
                    let rc = libusb_bulk_transfer(handle, endpointIn, &buffer, Int32(bufferSize), &transferred, timeout)
                    if rc != 0 || transferred == 0 { break }
                    result.append(contentsOf: buffer[0..<Int(transferred)])
                    remaining -= Int(transferred)
                }
            }
        }
        return result
    }

    private func parseContentLength(_ headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func logUSB(_ message: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PaperCat.log")
        let line = "[\(Date())] [USB] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let handle = try? FileHandle(forWritingTo: logPath) {
                    handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
                }
            } else { try? data.write(to: logPath) }
        }
    }

    static func extractXMLValue(from xml: String, tag: String) -> String? {
        let pattern = "<(?:[a-zA-Z0-9]+:)?\(tag)>(.*?)</(?:[a-zA-Z0-9]+:)?\(tag)>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           let range = Range(match.range(at: 1), in: xml) {
            return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

// MARK: - HTTP Response

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) throws -> HTTPResponse {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { throw USBError.malformedResponse }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { throw USBError.malformedResponse }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw USBError.malformedResponse }
        let parts = statusLine.components(separatedBy: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { throw USBError.malformedResponse }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let ci = line.firstIndex(of: ":") {
                headers[String(line[..<ci]).lowercased().trimmingCharacters(in: .whitespaces)] =
                    String(line[line.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        var body = data[headerEnd.upperBound...]
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            body = Self.decodeChunked(Data(body))[...]
        }
        return HTTPResponse(statusCode: code, headers: headers, body: Data(body))
    }

    private static func decodeChunked(_ data: Data) -> Data {
        var result = Data()
        var offset = 0
        let bytes = Array(data)
        while offset < bytes.count {
            var lineEnd = offset
            while lineEnd < bytes.count - 1 {
                if bytes[lineEnd] == 0x0D && bytes[lineEnd + 1] == 0x0A { break }
                lineEnd += 1
            }
            let sizeStr = String(bytes: bytes[offset..<lineEnd], encoding: .utf8) ?? "0"
            guard let chunkSize = UInt(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16), chunkSize > 0 else { break }
            let chunkStart = lineEnd + 2
            let chunkEnd = chunkStart + Int(chunkSize)
            if chunkEnd <= bytes.count { result.append(contentsOf: bytes[chunkStart..<chunkEnd]) }
            offset = chunkEnd + 2
        }
        return result
    }

    var bodyString: String? { String(data: body, encoding: .utf8) }
}

private extension Data {
    func hasSuffix(_ string: String) -> Bool {
        let suffix = Data(string.utf8)
        guard count >= suffix.count else { return false }
        return self[(count - suffix.count)...] == suffix
    }
}

enum USBError: LocalizedError {
    case notInitialized, initFailed(code: Int32), noDeviceFound, openFailed(code: Int32)
    case configFailed, interfaceNotFound, endpointsNotFound, claimFailed(code: Int32)
    case notConnected, writeFailed(code: Int32), readFailed(code: Int32), malformedResponse

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "USB not initialized"
        case .initFailed(let c): return "USB init failed (code \(c))"
        case .noDeviceFound: return "HP LaserJet Pro MFP M125a not found on USB"
        case .openFailed(let c): return "Could not open USB device (code \(c))"
        case .configFailed: return "Could not read USB configuration"
        case .interfaceNotFound: return "Scanner interface not found"
        case .endpointsNotFound: return "USB bulk endpoints not found"
        case .claimFailed(let c): return "Could not claim USB interface (code \(c))"
        case .notConnected: return "USB device not connected"
        case .writeFailed(let c): return "USB write failed (code \(c))"
        case .readFailed(let c): return "USB read failed (code \(c))"
        case .malformedResponse: return "Malformed HTTP response from device"
        }
    }
}
