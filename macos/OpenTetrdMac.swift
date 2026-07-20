import AppKit
import Darwin
import Foundation

private enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return "알 수 없는 오류"
    }
}

private func closeSocket(_ fd: Int32) {
    if fd >= 0 { Darwin.close(fd) }
}

private func readExact(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { throw AppError.message("메모리 오류") }
        while offset < count {
            let received = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
            if received == 0 { throw AppError.message("연결이 종료됐습니다") }
            if received < 0 {
                if errno == EINTR { continue }
                throw AppError.message("소켓 읽기 실패: \(String(cString: strerror(errno)))")
            }
            offset += received
        }
    }
    return data
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        while offset < data.count {
            let sent = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
            if sent < 0 {
                if errno == EINTR { continue }
                throw AppError.message("소켓 쓰기 실패: \(String(cString: strerror(errno)))")
            }
            offset += sent
        }
    }
}

private final class SocksServer {
    private let queue = DispatchQueue(label: "dev.opentetrd.socks.accept")
    private var source: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private(set) var isRunning = false
    var logger: ((String) -> Void)?

    func start(port: UInt16 = 1088) throws {
        guard !isRunning else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("SOCKS 소켓을 만들 수 없습니다") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = String(cString: strerror(errno))
            closeSocket(fd)
            throw AppError.message("127.0.0.1:\(port)을 열 수 없습니다: \(detail)")
        }
        guard Darwin.listen(fd, 32) == 0 else {
            closeSocket(fd)
            throw AppError.message("SOCKS 대기열을 시작할 수 없습니다")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        isRunning = true
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptConnections() }
        readSource.setCancelHandler { closeSocket(fd) }
        source = readSource
        readSource.resume()
        logger?("Mac SOCKS5가 127.0.0.1:\(port)에서 시작됐습니다.")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source?.cancel()
        source = nil
        listenFD = -1
        logger?("Mac SOCKS5를 중지했습니다.")
    }

    private func acceptConnections() {
        while isRunning {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func connectRelay() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("릴레이 소켓 생성 실패") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8787).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            closeSocket(fd)
            throw AppError.message("Android 릴레이 연결 실패: \(detail)")
        }
        return fd
    }

    private func handle(_ client: Int32) {
        var relay: Int32 = -1
        defer {
            closeSocket(relay)
            closeSocket(client)
        }
        do {
            let greeting = [UInt8](try readExact(client, 2))
            guard greeting[0] == 5 else { throw AppError.message("SOCKS5가 아닌 요청") }
            let methods = [UInt8](try readExact(client, Int(greeting[1])))
            guard methods.contains(0) else {
                try writeAll(client, Data([5, 255]))
                return
            }
            try writeAll(client, Data([5, 0]))
            let request = [UInt8](try readExact(client, 4))
            guard request[0] == 5, request[1] == 1, request[2] == 0 else {
                throw AppError.message("SOCKS CONNECT만 지원합니다")
            }
            let addressType = request[3]
            let hostBytes: Data
            switch addressType {
            case 1: hostBytes = try readExact(client, 4)
            case 4: hostBytes = try readExact(client, 16)
            case 3:
                let length = Int([UInt8](try readExact(client, 1))[0])
                guard length > 0 else { throw AppError.message("빈 호스트") }
                hostBytes = try readExact(client, length)
            default: throw AppError.message("지원하지 않는 주소 형식")
            }
            let portBytes = [UInt8](try readExact(client, 2))
            var relayRequest = Data("OTR1".utf8)
            relayRequest.append(addressType)
            relayRequest.append(contentsOf: portBytes)
            let length = UInt16(hostBytes.count)
            relayRequest.append(UInt8(length >> 8))
            relayRequest.append(UInt8(length & 0xff))
            relayRequest.append(hostBytes)

            relay = try connectRelay()
            try writeAll(relay, relayRequest)
            let status = [UInt8](try readExact(relay, 1))[0]
            guard status == 0 else { throw AppError.message("휴대폰이 목적지 연결을 거부했습니다 (\(status))") }
            try writeAll(client, Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
            bridge(client, relay)
            relay = -1
        } catch {
            logger?("연결 오류: \(error.localizedDescription)")
            try? writeAll(client, Data([5, 1, 0, 1, 0, 0, 0, 0, 0, 0]))
        }
    }

    private func bridge(_ left: Int32, _ right: Int32) {
        let group = DispatchGroup()
        func pump(_ source: Int32, _ destination: Int32) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.recv(source, &buffer, buffer.count, 0)
                if count <= 0 { break }
                var sent = 0
                while sent < count {
                    let result = buffer.withUnsafeBytes { raw in
                        Darwin.send(destination, raw.baseAddress!.advanced(by: sent), count - sent, 0)
                    }
                    if result <= 0 { return }
                    sent += result
                }
            }
            Darwin.shutdown(destination, SHUT_WR)
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(left, right)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(right, left)
            group.leave()
        }
        group.wait()
        closeSocket(right)
    }
}

private final class TunnelManager {
    let socks = SocksServer()
    private(set) var running = false
    private var createdForward = false
    private var serial: String?
    var logger: ((String) -> Void)? {
        didSet { socks.logger = logger }
    }

    private var adbPath: String? {
        ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw AppError.message((stderr + stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    func start() throws -> String {
        guard !running else { return serial ?? "" }
        guard let adb = adbPath else { throw AppError.message("adb를 찾을 수 없습니다") }
        let devicesOutput = try command(adb, ["devices"])
        let devices = devicesOutput.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            return fields.count >= 2 && fields[1] == "device" ? String(fields[0]) : nil
        }
        guard devices.count == 1 else {
            throw AppError.message("승인된 Android USB 장치가 정확히 1대여야 합니다 (현재 \(devices.count)대)")
        }
        let selected = devices[0]
        let mappings = try command(adb, ["forward", "--list"])
        let relevant = mappings.split(separator: "\n").filter { $0.contains("tcp:8787") }
        if let mapping = relevant.first {
            let fields = mapping.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, fields[0] == selected, fields[1] == "tcp:8787", fields[2] == "tcp:8787" else {
                throw AppError.message("기존 tcp:8787 ADB 매핑을 덮어쓰지 않습니다: \(mapping)")
            }
            logger?("기존 ADB 포워딩을 그대로 사용합니다.")
        } else {
            _ = try command(adb, ["-s", selected, "forward", "tcp:8787", "tcp:8787"])
            createdForward = true
            logger?("USB ADB 포워딩 tcp:8787을 만들었습니다.")
        }
        do {
            try socks.start()
        } catch {
            if createdForward { try? removeForward(adb: adb, device: selected) }
            createdForward = false
            throw error
        }
        serial = selected
        running = true
        return selected
    }

    func stop() {
        socks.stop()
        if createdForward, let adb = adbPath, let device = serial {
            try? removeForward(adb: adb, device: device)
            logger?("앱이 만든 ADB 포워딩을 제거했습니다.")
        }
        createdForward = false
        serial = nil
        running = false
    }

    private func removeForward(adb: String, device: String) throws {
        _ = try command(adb, ["-s", device, "forward", "--remove", "tcp:8787"])
    }

    func test() throws {
        guard running else { throw AppError.message("먼저 OpenTetrd를 시작하세요") }
        _ = try command("/usr/bin/curl", [
            "--fail", "--silent", "--show-error", "--output", "/dev/null",
            "--connect-timeout", "10", "--max-time", "30",
            "--proxy", "socks5h://127.0.0.1:1088",
            "https://connectivitycheck.gstatic.com/generate_204"
        ])
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = TunnelManager()
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var deviceLabel: NSTextField!
    private var logView: NSTextView!
    private var startButton: NSButton!
    private var testButton: NSButton!
    private var stopButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        manager.logger = { [weak self] message in self?.appendLog(message) }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "OpenTetrd"
        window.center()
        window.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "OpenTetrd for macOS")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        root.addArrangedSubview(title)

        let explanation = NSTextField(wrappingLabelWithString:
            "휴대폰 OpenTetrd 릴레이와 USB로 연결합니다. 현재 Tetrd를 보호하기 위해 시스템 라우트, DNS, 방화벽과 프록시는 변경하지 않습니다.")
        explanation.font = .systemFont(ofSize: 14)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3
        root.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true

        statusLabel = NSTextField(labelWithString: "● 중지됨")
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        root.addArrangedSubview(statusLabel)
        deviceLabel = NSTextField(labelWithString: "장치: 연결 확인 전")
        root.addArrangedSubview(deviceLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        startButton = NSButton(title: "OpenTetrd 시작", target: self, action: #selector(startTunnel))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        testButton = NSButton(title: "연결 시험", target: self, action: #selector(testTunnel))
        testButton.isEnabled = false
        stopButton = NSButton(title: "중지", target: self, action: #selector(stopTunnel))
        stopButton.isEnabled = false
        buttons.addArrangedSubview(startButton)
        buttons.addArrangedSubview(testButton)
        buttons.addArrangedSubview(stopButton)
        root.addArrangedSubview(buttons)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView = NSTextView()
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.string = "휴대폰에서 OpenTetrd의 ‘릴레이 시작’을 먼저 누르세요.\n"
        scroll.documentView = logView
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        window.makeKeyAndOrderFront(nil)
    }

    private func setBusy(_ busy: Bool) {
        startButton.isEnabled = !busy && !manager.running
        testButton.isEnabled = !busy && manager.running
        stopButton.isEnabled = !busy && manager.running
    }

    private func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            self.logView.string += "[\(formatter.string(from: Date()))] \(message)\n"
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func startTunnel() {
        setBusy(true)
        appendLog("연결 준비를 시작합니다…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let serial = try self.manager.start()
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "● 실행 중 · SOCKS 127.0.0.1:1088"
                    self.statusLabel.textColor = .systemGreen
                    self.deviceLabel.stringValue = "장치: \(serial)"
                    self.setBusy(false)
                }
                self.appendLog("준비 완료. ‘연결 시험’을 누르세요.")
            } catch {
                self.appendLog("시작 실패: \(error.localizedDescription)")
                DispatchQueue.main.async { self.setBusy(false) }
            }
        }
    }

    @objc private func testTunnel() {
        setBusy(true)
        appendLog("한 개의 HTTPS 요청을 휴대폰 경로로 시험합니다…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.manager.test()
                self.appendLog("성공: 요청이 OpenTetrd 휴대폰 경로를 통과했습니다.")
            } catch {
                self.appendLog("시험 실패: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self.setBusy(false) }
        }
    }

    @objc private func stopTunnel() {
        manager.stop()
        statusLabel.stringValue = "● 중지됨"
        statusLabel.textColor = .labelColor
        deviceLabel.stringValue = "장치: 연결 확인 전"
        setBusy(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
