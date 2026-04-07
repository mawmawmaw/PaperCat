import Foundation

enum DIMEImageExtractor {
    struct ExtractionResult {
        let jpegData: Data
        let payloadData: Data
        let mimeType: String
    }

    enum ExtractionError: LocalizedError {
        case emptyResponse
        case invalidChunkedEncoding
        case imagePayloadNotFound
        case jpegNotFound

        var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "Scanner returned an empty response."
            case .invalidChunkedEncoding:
                return "Failed to decode chunked scan response."
            case .imagePayloadNotFound:
                return "No DIME image payload found in scan response."
            case .jpegNotFound:
                return "No JPEG markers found in scan payload."
            }
        }
    }

    static func extract(from rawResponse: Data) throws -> ExtractionResult {
        guard !rawResponse.isEmpty else { throw ExtractionError.emptyResponse }

        let bodyData = try extractHTTPBody(from: rawResponse)
        guard !bodyData.isEmpty else { throw ExtractionError.emptyResponse }

        if let dimePayload = extractImagePayloadFromDIME(bodyData),
           let jpeg = trimToJPEG(dimePayload.payload) {
            return ExtractionResult(jpegData: jpeg, payloadData: dimePayload.payload, mimeType: dimePayload.mimeType)
        }

        if let jpeg = trimToJPEG(bodyData) {
            return ExtractionResult(jpegData: jpeg, payloadData: bodyData, mimeType: "image/jpeg")
        }

        throw ExtractionError.imagePayloadNotFound
    }

    private static func extractHTTPBody(from rawResponse: Data) throws -> Data {
        let bytes = [UInt8](rawResponse)
        guard !bytes.isEmpty else { throw ExtractionError.emptyResponse }

        let httpPattern = Array("HTTP/1.1".utf8)
        let headerPattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

        guard let httpStart = findSequence(in: bytes, pattern: httpPattern, start: 0),
              let headerEnd = findSequence(in: bytes, pattern: headerPattern, start: httpStart) else {
            return rawResponse
        }

        let headers = String(bytes: bytes[httpStart..<headerEnd], encoding: .utf8) ?? ""
        let bodyStart = headerEnd + headerPattern.count
        guard bodyStart <= bytes.count else { throw ExtractionError.emptyResponse }
        let body = Array(bytes[bodyStart..<bytes.count])

        if headers.lowercased().contains("transfer-encoding: chunked") {
            let decoded = try decodeChunkedBody(body)
            return Data(decoded)
        }

        return Data(body)
    }

    private static func decodeChunkedBody(_ body: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        var offset = 0
        var sawChunk = false

        while offset < body.count {
            guard let lineEnd = findCRLF(in: body, from: offset) else {
                if sawChunk { break }
                throw ExtractionError.invalidChunkedEncoding
            }

            let lineBytes = body[offset..<lineEnd]
            var line = String(bytes: lineBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            offset = lineEnd + 2

            if line.isEmpty { continue }
            if let semicolon = line.firstIndex(of: ";") {
                line = String(line[..<semicolon])
            }

            guard let chunkSize = Int(line, radix: 16) else {
                if sawChunk { break }
                throw ExtractionError.invalidChunkedEncoding
            }

            if chunkSize == 0 {
                return output
            }

            guard offset + chunkSize <= body.count else {
                throw ExtractionError.invalidChunkedEncoding
            }

            output.append(contentsOf: body[offset..<(offset + chunkSize)])
            offset += chunkSize
            sawChunk = true

            if offset + 1 < body.count && body[offset] == 0x0D && body[offset + 1] == 0x0A {
                offset += 2
            }
        }

        guard sawChunk else { throw ExtractionError.invalidChunkedEncoding }
        return output
    }

    private static func extractImagePayloadFromDIME(_ data: Data) -> (payload: Data, mimeType: String)? {
        let bytes = [UInt8](data)
        var offset = 0
        var collectingImage = false
        var imagePayload: [UInt8] = []
        var mimeType = "image/unknown"

        while offset + 12 <= bytes.count {
            let flags = bytes[offset]
            let cf = (flags & 0x01) != 0
            let optionsLength = be16(bytes, offset + 2)
            let idLength = be16(bytes, offset + 4)
            let typeLength = be16(bytes, offset + 6)
            let dataLength = be32(bytes, offset + 8)

            var cursor = offset + 12
            guard cursor + optionsLength <= bytes.count else { return nil }
            cursor += optionsLength + padding4(optionsLength)

            guard cursor + idLength <= bytes.count else { return nil }
            cursor += idLength + padding4(idLength)

            guard cursor + typeLength <= bytes.count else { return nil }
            let typeBytes = Array(bytes[cursor..<(cursor + typeLength)])
            let typeString = String(bytes: typeBytes, encoding: .ascii) ?? ""
            cursor += typeLength + padding4(typeLength)

            guard cursor + dataLength <= bytes.count else { return nil }
            let payload = bytes[cursor..<(cursor + dataLength)]

            if !collectingImage && typeString.lowercased().hasPrefix("image/") {
                collectingImage = true
                mimeType = typeString
            }

            if collectingImage {
                imagePayload.append(contentsOf: payload)
                if !cf {
                    return (Data(imagePayload), mimeType)
                }
            }

            cursor += dataLength + padding4(dataLength)
            if cursor <= offset { return nil }
            offset = cursor
        }

        return nil
    }

    private static func trimToJPEG(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let soi: [UInt8] = [0xFF, 0xD8, 0xFF]
        guard let start = findSequence(in: bytes, pattern: soi, start: 0) else { return nil }

        var end = bytes.count
        if bytes.count >= 2 {
            for i in stride(from: bytes.count - 2, through: start, by: -1) {
                if bytes[i] == 0xFF && bytes[i + 1] == 0xD9 {
                    end = i + 2
                    break
                }
            }
        }

        guard start < end else { return nil }
        return Data(bytes[start..<end])
    }

    private static func findCRLF(in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= 2, start < bytes.count - 1 else { return nil }
        for i in start..<(bytes.count - 1) {
            if bytes[i] == 0x0D && bytes[i + 1] == 0x0A {
                return i
            }
        }
        return nil
    }

    private static func findSequence(in bytes: [UInt8], pattern: [UInt8], start: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        let firstIndex = max(0, start)
        guard firstIndex <= bytes.count - pattern.count else { return nil }

        for i in firstIndex...(bytes.count - pattern.count) {
            if bytes[i..<(i + pattern.count)].elementsEqual(pattern) {
                return i
            }
        }
        return nil
    }

    private static func padding4(_ length: Int) -> Int {
        let remainder = length % 4
        return remainder == 0 ? 0 : (4 - remainder)
    }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 24)
            | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8)
            | Int(bytes[offset + 3])
    }
}
