import Foundation
import Network

/// A deliberately small HTTP/1.1 reader for the gallery's GET-only API.
/// It never maps URL paths to files and accepts one request per connection.
nonisolated struct WebGalleryHTTPRequest {
    let target: String
    let headers: [String: String]
}

nonisolated struct WebGalleryHTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
    let file: WebGalleryHTTPFile?
    let unsatisfiedRangeLength: Int64?
    let cacheable: Bool

    init(status: Int, contentType: String, body: Data,
         file: WebGalleryHTTPFile? = nil, unsatisfiedRangeLength: Int64? = nil,
         cacheable: Bool = false) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.file = file
        self.unsatisfiedRangeLength = unsatisfiedRangeLength
        self.cacheable = cacheable
    }

    static func text(_ status: Int, _ message: String) -> Self {
        Self(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    static func rangeNotSatisfiable(totalLength: Int64) -> Self {
        Self(status: 416, contentType: "text/plain; charset=utf-8",
             body: Data(), unsatisfiedRangeLength: totalLength)
    }

    func serializedHeaders() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 408: reason = "Request Timeout"
        case 413: reason = "Content Too Large"
        case 416: reason = "Range Not Satisfiable"
        case 500: reason = "Internal Server Error"
        default: reason = "Error"
        }
        let length = file?.length ?? Int64(body.count)
        let rangeHeaders: String
        if let file {
            rangeHeaders = "Accept-Ranges: bytes\r\n" + (status == 206
                ? "Content-Range: bytes \(file.offset)-\(file.offset + file.length - 1)/\(file.totalLength)\r\n"
                : "")
        } else if let unsatisfiedRangeLength {
            rangeHeaders = "Accept-Ranges: bytes\r\nContent-Range: bytes */\(unsatisfiedRangeLength)\r\n"
        } else {
            rangeHeaders = ""
        }
        let cacheHeaders = cacheable
            ? "Cache-Control: private, max-age=3600\r\n"
            : "Cache-Control: no-store, max-age=0\r\nPragma: no-cache\r\n"
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(length)\r
        \(rangeHeaders)Connection: close\r
        \(cacheHeaders)X-Content-Type-Options: nosniff\r
        X-Frame-Options: DENY\r
        Referrer-Policy: strict-origin-when-cross-origin\r
        Cross-Origin-Resource-Policy: same-origin\r
        Content-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-inline' https://cdn.apple-mapkit.com; style-src 'self' 'unsafe-inline' https://cdn.apple-mapkit.com; img-src 'self' data: blob: https://*.apple.com https://*.apple-mapkit.com https://*.cdn-apple.com https://*.mzstatic.com; media-src 'self'; connect-src 'self' https://*.apple.com https://*.apple-mapkit.com https://*.cdn-apple.com https://*.mzstatic.com; font-src https://*.apple.com https://*.apple-mapkit.com; worker-src 'self' blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r
        \r

        """
        return Data(header.utf8)
    }
}

nonisolated struct WebGalleryHTTPFile {
    let url: URL
    let offset: Int64
    let length: Int64
    let totalLength: Int64
    let cleanupDirectory: URL?
}

final class WebGalleryHTTPConnection {
    private static let maximumHeaderBytes = 16_384
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PhotoLibraries.WebGallery.HTTP")
    private let onRequest: (WebGalleryHTTPRequest, @escaping (WebGalleryHTTPResponse) -> Void) -> Void
    private let onFinish: () -> Void
    private var bytes = Data()
    private var finished = false
    private var receivedRequest = false
    private var fileHandle: FileHandle?
    private var cleanupDirectory: URL?

    init(
        connection: NWConnection,
        onRequest: @escaping (WebGalleryHTTPRequest, @escaping (WebGalleryHTTPResponse) -> Void) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.connection = connection
        self.onRequest = onRequest
        self.onFinish = onFinish
    }

    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.receivedRequest else { return }
            self.send(.text(408, "Request timed out"))
        }
        receive()
    }

    func cancel() {
        queue.async { [weak self] in self?.finish() }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] content, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let content { self.bytes.append(content) }
            if self.bytes.count > Self.maximumHeaderBytes {
                self.send(.text(413, "Request headers too large"))
                return
            }
            if let end = self.bytes.range(of: Data("\r\n\r\n".utf8)) {
                guard self.bytes.count == end.upperBound else {
                    self.send(.text(400, "Unexpected request body"))
                    return
                }
                let headerData = self.bytes.prefix(upTo: end.lowerBound)
                guard let request = Self.parse(headerData) else {
                    self.send(.text(400, "Invalid request"))
                    return
                }
                self.receivedRequest = true
                self.onRequest(request) { [weak self] response in
                    if let self {
                        self.queue.async { self.send(response) }
                    } else if let directory = response.file?.cleanupDirectory {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }
                return
            }
            if isComplete || error != nil {
                self.finish()
            } else {
                self.receive()
            }
        }
    }

    private static func parse(_ data: Data) -> WebGalleryHTTPRequest? {
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        let lines = source.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "GET",
              parts[2] == "HTTP/1.1",
              parts[1].first == "/",
              !parts[1].hasPrefix("//") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || $0 == 45 }),
                  !headers.keys.contains(name),
                  !value.contains("\r"), !value.contains("\n") else { return nil }
            headers[name] = value
        }
        guard headers["host"] != nil,
              headers["transfer-encoding"] == nil,
              headers["content-length"].map({ $0 == "0" }) ?? true else { return nil }
        return WebGalleryHTTPRequest(target: String(parts[1]), headers: headers)
    }

    private func send(_ response: WebGalleryHTTPResponse) {
        guard !finished else {
            if let directory = response.file?.cleanupDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
            return
        }
        if let file = response.file {
            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                try handle.seek(toOffset: UInt64(file.offset))
                fileHandle = handle
                cleanupDirectory = file.cleanupDirectory
            } catch {
                if let directory = file.cleanupDirectory {
                    try? FileManager.default.removeItem(at: directory)
                }
                send(.text(500, "Video temporarily unavailable"))
                return
            }
            connection.send(content: response.serializedHeaders(), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if error != nil { self.finish() }
                    else { self.sendFileChunk(remaining: file.length) }
                }
            })
        } else {
            var data = response.serializedHeaders()
            data.append(response.body)
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.finish() }
            })
        }
    }

    private func sendFileChunk(remaining: Int64) {
        guard !finished else { return }
        guard remaining > 0 else { finish(); return }
        do {
            let chunk = try fileHandle?.read(upToCount: Int(min(remaining, 256 * 1_024))) ?? Data()
            guard !chunk.isEmpty else { finish(); return }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if error != nil { self.finish() }
                    else { self.sendFileChunk(remaining: remaining - Int64(chunk.count)) }
                }
            })
        } catch {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        try? fileHandle?.close()
        fileHandle = nil
        if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
        cleanupDirectory = nil
        connection.cancel()
        onFinish()
    }
}
