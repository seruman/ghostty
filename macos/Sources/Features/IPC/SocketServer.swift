import Foundation
import Network
import OSLog

/// Unix domain socket server for IPC
final class SocketServer {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "SocketServer"
    )

    let socketPath: String
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let actionHandler: IPCActionHandler
    private var handler: Handler?
    private let acceptQueue = DispatchQueue(label: "com.mitchellh.ghostty.ipc.accept")
    private let connectionQueue = DispatchQueue(label: "com.mitchellh.ghostty.ipc.connection", attributes: .concurrent)

    @MainActor
    init(socketPath: String, actionHandler: IPCActionHandler) {
        self.socketPath = socketPath
        self.actionHandler = actionHandler
        self.handler = Handler(actionHandler: actionHandler)
    }

    func start() throws {
        // Remove any existing socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create NWParameters for Unix domain socket
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()

        // Create the listener on Unix domain socket
        guard let port = NWEndpoint.Port(rawValue: 0) else {
            throw SocketServerError.failedToCreateListener
        }

        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            Self.logger.error("Failed to create listener: \(error)")
            throw error
        }

        // We can't use NWListener directly with Unix sockets in a straightforward way,
        // so we'll use a lower-level approach with Darwin sockets
        try startDarwinSocket()
    }

    private func startDarwinSocket() throws {
        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketServerError.failedToCreateSocket
        }

        // Set up the address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy the path to the socket address
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SocketServerError.pathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        // Bind the socket
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw SocketServerError.failedToBind(errno: errno)
        }

        // Set socket permissions to 0600 (owner read/write only)
        chmod(socketPath, 0o600)

        // Listen for connections
        guard listen(fd, 5) == 0 else {
            close(fd)
            throw SocketServerError.failedToListen(errno: errno)
        }

        Self.logger.info("IPC socket server listening on \(self.socketPath)")

        // Accept connections in background
        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    private func acceptLoop(fd: Int32) {
        Self.logger.info("Accept loop started on fd=\(fd)")
        while true {
            Self.logger.debug("Waiting for connection...")
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(fd, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientFd >= 0 else {
                if errno == EINTR { continue }
                Self.logger.error("Accept failed: \(errno)")
                break
            }

            Self.logger.info("New IPC connection accepted, clientFd=\(clientFd)")
            // Handle on global queue to avoid blocking accept loop
            // Use strong self - the server must stay alive while handling connections
            let clientFdCopy = clientFd
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleConnectionSync(fd: clientFdCopy)
            }
        }

        close(fd)
    }

    private func handleConnectionSync(fd: Int32) {
        defer {
            Self.logger.info("Closing connection fd=\(fd)")
            close(fd)
        }

        Self.logger.info("Handling connection fd=\(fd)")

        var buffer = [UInt8](repeating: 0, count: 65536)
        var accumulated = Data()

        // Read until we get a complete request (newline-terminated)
        while true {
            Self.logger.info("Waiting to read from fd=\(fd)")
            let bytesRead = read(fd, &buffer, buffer.count)
            Self.logger.info("Read \(bytesRead) bytes from fd=\(fd)")

            if bytesRead <= 0 {
                break
            }

            accumulated.append(contentsOf: buffer[0..<bytesRead])

            // Process complete line (newline-delimited JSON)
            if let newlineIndex = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = accumulated[..<newlineIndex]
                Self.logger.info("Processing request: \(String(data: Data(lineData), encoding: .utf8) ?? "?")")

                if let response = self.processRequest(Data(lineData)) {
                    Self.logger.info("Got response, writing...")
                    var responseData = response
                    responseData.append(UInt8(ascii: "\n"))
                    _ = responseData.withUnsafeBytes { ptr in
                        write(fd, ptr.baseAddress, ptr.count)
                    }
                    Self.logger.info("Response written")
                } else {
                    Self.logger.info("No response from processRequest")
                }
                // Close connection after responding (request-response model)
                break
            }
        }
    }

    private func processRequest(_ data: Data) -> Data? {
        Self.logger.debug("processRequest called")
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // Parse the request
        let response: JSONValue
        do {
            let request = try decoder.decode(Request.self, from: data)
            Self.logger.debug("Decoded request: method=\(request.method)")

            // Handle on main thread since UI operations require it
            var result: JSONValue?
            Self.logger.debug("Dispatching to main thread...")
            DispatchQueue.main.sync {
                Self.logger.debug("On main thread, calling handler")
                result = self.handler?.handle(request: request)
                Self.logger.debug("Handler returned")
            }
            Self.logger.debug("Back from main thread dispatch")
            guard let result else {
                return try? encoder.encode(JSONValue.object(["error": .string("Handler not available")]))
            }
            response = result
        } catch {
            Self.logger.error("Failed to parse request: \(error)")
            response = .object(["error": .string("Parse error: \(error.localizedDescription)")])
        }

        // Encode the response
        do {
            return try encoder.encode(response)
        } catch {
            Self.logger.error("Failed to encode response: \(error)")
            return nil
        }
    }

    func stop() {
        Self.logger.info("Stopping IPC socket server")

        // Close all connections
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()

        // Stop the listener
        listener?.cancel()
        listener = nil

        // Remove the socket file
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

// MARK: - Instance Registry

extension SocketServer {
    /// Register this instance in the global registry file
    func registerInstance() {
        let registryPath = "/tmp/ghostty.\(getuid()).instances"

        let entry = InstanceEntry(
            pid: ProcessInfo.processInfo.processIdentifier,
            socket: socketPath,
            started: ISO8601DateFormatter().string(from: Date())
        )

        do {
            let encoder = JSONEncoder()
            var data = try encoder.encode(entry)
            data.append(UInt8(ascii: "\n"))

            // Append to registry file
            if FileManager.default.fileExists(atPath: registryPath) {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: registryPath))
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: URL(fileURLWithPath: registryPath))
                chmod(registryPath, 0o600)
            }

            Self.logger.debug("Registered instance in \(registryPath)")
        } catch {
            Self.logger.error("Failed to register instance: \(error)")
        }
    }

    /// Unregister this instance from the global registry file
    func unregisterInstance() {
        let registryPath = "/tmp/ghostty.\(getuid()).instances"
        let myPid = ProcessInfo.processInfo.processIdentifier

        guard FileManager.default.fileExists(atPath: registryPath) else { return }

        do {
            let content = try String(contentsOfFile: registryPath, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            let decoder = JSONDecoder()

            let filteredLines = lines.filter { line in
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(InstanceEntry.self, from: data) else {
                    return false
                }
                return entry.pid != myPid
            }

            if filteredLines.isEmpty {
                try FileManager.default.removeItem(atPath: registryPath)
            } else {
                let newContent = filteredLines.joined(separator: "\n") + "\n"
                try newContent.write(toFile: registryPath, atomically: true, encoding: .utf8)
            }

            Self.logger.debug("Unregistered instance from \(registryPath)")
        } catch {
            Self.logger.error("Failed to unregister instance: \(error)")
        }
    }

    private struct InstanceEntry: Codable {
        let pid: Int32
        let socket: String
        let started: String
    }
}

// MARK: - Errors

enum SocketServerError: Error {
    case failedToCreateListener
    case failedToCreateSocket
    case pathTooLong
    case failedToBind(errno: Int32)
    case failedToListen(errno: Int32)
}
