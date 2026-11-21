import Foundation
import Network

/// Loopback-only HLS relay. It supplies the required Referer upstream and
/// rewrites playlists so AVPlayer never sees non-standard segment extensions.
/// Unguessable per-launch tokens keep other local processes and web pages from
/// using the relay as an open proxy.
final class HLSProxy: @unchecked Sendable {
    static let shared = HLSProxy()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.nik.crackstreams.hls-proxy")
    private let token = UUID().uuidString + UUID().uuidString
    private let tasksLock = NSLock()
    private var requestTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private(set) var port: UInt16

    init(port: UInt16 = 0) {
        self.port = port
    }

    var isRunning: Bool { listener != nil && port != 0 }

    func start() throws {
        guard !isRunning else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw NSError(domain: "HLSProxy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The local playback service could not start."])
        }
        self.port = port
        self.listener = listener
    }

    func localURL(for upstream: URL, referer: String?, kind: String = "m.m3u8") -> URL {
        var string = "http://127.0.0.1:\(port)/\(kind)?u=\(Self.encode(upstream.absoluteString))&t=\(token)"
        if let referer { string += "&r=\(Self.encode(referer))" }
        return URL(string: string)!
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cancelRequest(for: key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let key = ObjectIdentifier(connection)
                let task = Task { await self.respond(to: connection, head: head) }
                self.tasksLock.withLock { self.requestTasks[key] = task }
            } else if error != nil || complete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func cancelRequest(for key: ObjectIdentifier) {
        let task = tasksLock.withLock { requestTasks.removeValue(forKey: key) }
        task?.cancel()
    }

    private func respond(to connection: NWConnection, head: String) async {
        defer { cancelRequest(for: ObjectIdentifier(connection)) }
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(connection, status: 405, body: Data())
        }
        let method = String(parts[0])
        let target = String(parts[1])
        guard validHost(in: lines), let queryStart = target.firstIndex(of: "?") else {
            return send(connection, status: 403, body: Data())
        }
        let path = String(target[..<queryStart])
        var parameters: [String: String] = [:]
        for pair in target[target.index(after: queryStart)...].split(separator: "&") {
            let values = pair.split(separator: "=", maxSplits: 1)
            guard values.count == 2 else { continue }
            parameters[String(values[0])] = String(values[1]).removingPercentEncoding
        }
        guard parameters["t"] == token, let source = parameters["u"],
              let upstream = URL(string: source),
              let scheme = upstream.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return send(connection, status: 403, body: Data())
        }
        let referer = parameters["r"]
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

        do {
            let (data, response) = try await Net.data(
                upstream, referer: referer, range: range, maximumBytes: Net.maximumSegmentBytes
            )
            let code = response.statusCode
            guard (200..<300).contains(code) else {
                return send(connection, status: code, body: Data(), head: method == "HEAD")
            }
            guard !Task.isCancelled else { return connection.cancel() }

            if String(decoding: data.prefix(7), as: UTF8.self) == "#EXTM3U" {
                guard data.count <= Net.maximumPlaylistBytes else { throw ResolveError.responseTooLarge }
                let rewritten = rewrite(
                    playlist: String(decoding: data, as: UTF8.self), base: upstream, referer: referer
                )
                return send(connection, status: 200, body: Data(rewritten.utf8),
                            contentType: "application/vnd.apple.mpegurl", head: method == "HEAD")
            }

            let type = path.hasSuffix(".ts") ? "video/MP2T" :
                (response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
            if code == 206 {
                return send(connection, status: 206, body: data, contentType: type,
                            contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                            head: method == "HEAD")
            }
            if let range {
                guard let slice = Self.slice(data, range: range) else {
                    return send(connection, status: 416, body: Data(), contentType: type,
                                contentRange: "bytes */\(data.count)", head: method == "HEAD")
                }
                return send(connection, status: 206, body: slice.data, contentType: type,
                            contentRange: "bytes \(slice.start)-\(slice.end)/\(data.count)",
                            head: method == "HEAD")
            }
            send(connection, status: 200, body: data, contentType: type, head: method == "HEAD")
        } catch {
            if !Task.isCancelled { send(connection, status: 502, body: Data(), head: method == "HEAD") }
        }
    }

    private func validHost(in lines: [String]) -> Bool {
        guard let host = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("host:") })?
            .dropFirst("host:".count).trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "[::1]:\(port)"
    }

    static func slice(_ data: Data, range: String) -> (data: Data, start: Int, end: Int)? {
        guard range.hasPrefix("bytes="), !range.contains(","), !data.isEmpty else { return nil }
        let spec = range.dropFirst("bytes=".count)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        let start: Int, end: Int
        if spec[0].isEmpty {
            guard let length = Int(spec[1]), length > 0 else { return nil }
            start = max(0, data.count - length)
            end = data.count - 1
        } else {
            guard let first = Int(spec[0]), first >= 0 else { return nil }
            start = first
            end = min(Int(spec[1]) ?? (data.count - 1), data.count - 1)
        }
        guard start <= end, start < data.count, end >= 0 else { return nil }
        return (data.subdata(in: start..<(end + 1)), start, end)
    }

    private func send(_ connection: NWConnection, status: Int, body: Data,
                      contentType: String = "application/octet-stream",
                      contentRange: String? = nil, head: Bool = false) {
        let reasons = [200: "OK", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 502: "Bad Gateway"]
        let safeType = contentType.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        var header = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        header += "Content-Type: \(safeType)\r\nContent-Length: \(body.count)\r\n"
        header += "Accept-Ranges: bytes\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        if let contentRange { header += "Content-Range: \(contentRange)\r\n" }
        header += "Connection: close\r\n\r\n"
        var output = Data(header.utf8)
        if !head { output.append(body) }
        connection.send(content: output, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Playlist rewriting

    func rewrite(playlist: String, base: URL, referer: String?) -> String {
        var nextIsVariant = false
        var output: [String] = []

        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { output.append(raw); continue }
            if line.hasPrefix("#") {
                nextIsVariant = line.hasPrefix("#EXT-X-STREAM-INF")
                output.append(rewriteAttributeURI(in: line, base: base, referer: referer))
                continue
            }
            guard let absolute = URL(string: line, relativeTo: base)?.absoluteURL,
                  let scheme = absolute.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                output.append(raw)
                continue
            }
            let kind = nextIsVariant ? "m.m3u8" : "s.\(Self.segmentExtension(absolute))"
            output.append(localURL(for: absolute, referer: referer, kind: kind).absoluteString)
            nextIsVariant = false
        }
        return output.joined(separator: "\n")
    }

    private func rewriteAttributeURI(in tag: String, base: URL, referer: String?) -> String {
        guard tag.contains("URI=\""), let regex = try? NSRegularExpression(pattern: #"URI="([^"]*)""#) else { return tag }
        var result = tag
        let matches = regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: tag), let capture = Range(match.range(at: 1), in: tag),
                  let absolute = URL(string: String(tag[capture]), relativeTo: base)?.absoluteURL,
                  let scheme = absolute.scheme?.lowercased(), ["http", "https"].contains(scheme) else { continue }
            let kind: String
            if tag.hasPrefix("#EXT-X-MEDIA") || tag.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                kind = "m.m3u8"
            } else if tag.hasPrefix("#EXT-X-KEY") || tag.hasPrefix("#EXT-X-SESSION-KEY") {
                kind = "k.key"
            } else if tag.hasPrefix("#EXT-X-MAP") {
                kind = "i.mp4"
            } else {
                kind = "s.\(Self.segmentExtension(absolute))"
            }
            let replacement = "URI=\"\(localURL(for: absolute, referer: referer, kind: kind).absoluteString)\""
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    private static func segmentExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["m4s", "mp4", "aac", "m4a", "cmfv", "cmfa"].contains(ext) ? ext : "ts"
    }
}
