import Foundation
@preconcurrency import Virtualization

final class VPhoneAuthBroker: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private static let port: UInt32 = 1338
    private static let protocolVersion = 1

    private let listener = VZVirtioSocketListener()
    private let connectionsLock = NSLock()
    private var connections: [VZVirtioSocketConnection] = []

    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedData: Data?
        private var storedError: Error?

        func set(data: Data?, error: Error?) {
            lock.lock()
            storedData = data
            storedError = error
            lock.unlock()
        }

        func get() -> (Data?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (storedData, storedError)
        }
    }

    override init() {
        super.init()
        listener.delegate = self
    }

    func start(device: VZVirtioSocketDevice) {
        device.setSocketListener(listener, forPort: Self.port)
        print("[auth-broker] listening on vsock port \(Self.port)")
    }

    func stop(device: VZVirtioSocketDevice?) {
        device?.removeSocketListener(forPort: Self.port)
        connectionsLock.lock()
        connections.removeAll()
        connectionsLock.unlock()
    }

    func listener(
        _: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from _: VZVirtioSocketDevice
    ) -> Bool {
        let fd = connection.fileDescriptor
        connectionsLock.lock()
        connections.append(connection)
        connectionsLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.handle(fd: fd)
            self?.connectionsLock.lock()
            self?.connections.removeAll { $0.fileDescriptor == fd }
            self?.connectionsLock.unlock()
        }
        return true
    }

    private static func handle(fd: Int32) {
        guard let request = readMessage(fd: fd) else {
            return
        }

        let kind = request["kind"] as? String ?? ""
        let payload = request["payload"] as? [String: Any] ?? [:]
        let response = handle(kind: kind, payload: payload)
        _ = writeMessage(fd: fd, dict: response)
    }

    private static func handle(kind: String, payload: [String: Any]) -> [String: Any] {
        print("[auth-broker] request kind=\(kind) keys=\(payload.keys.sorted())")
        switch kind {
        case "ping":
            return [
                "v": protocolVersion,
                "t": "auth_broker_response",
                "ok": true,
                "kind": kind,
                "data": [
                    "broker": "vphone-auth-broker",
                    "capabilities": ["ping", "ams_signing_probe", "ams_sign_sap_setup"],
                ],
            ]
        case "ams_sign_sap_setup":
            return handleAMSSignSAPSetup(payload: payload)
        case "ams_signing_probe":
            return [
                "v": protocolVersion,
                "t": "auth_broker_response",
                "ok": true,
                "kind": kind,
                "data": [
                    "accepted": true,
                    "payload_keys": Array(payload.keys).sorted(),
                ],
            ]
        default:
            return [
                "v": protocolVersion,
                "t": "err",
                "ok": false,
                "kind": kind,
                "msg": "unsupported auth broker kind: \(kind)",
            ]
        }
    }

    private static func handleAMSSignSAPSetup(payload: [String: Any]) -> [String: Any] {
        if let emulatorURL = ProcessInfo.processInfo.environment["VPHONE_APPLE_EMULATOR_URL"], !emulatorURL.isEmpty {
            return handleAMSSignSAPSetupWithEmulator(baseURL: emulatorURL, payload: payload)
        }

        if ProcessInfo.processInfo.environment["VPHONE_AUTH_BROKER_FAKE_AMS"] == "1" {
            return fakeAMSSignSAPSetupResponse(payload: payload, source: "env")
        }

        return [
            "v": protocolVersion,
            "t": "auth_broker_response",
            "ok": false,
            "kind": "ams_sign_sap_setup",
            "stage": "scaffold",
            "msg": "ams_sign_sap_setup broker path is wired; host-side SAP signing is not implemented yet",
            "data": [
                "payload_keys": Array(payload.keys).sorted(),
                "expected_response": [
                    "headers": "Dictionary<String, String> of signed AMS/FairPlay HTTP headers to inject into the guest request",
                    "mescalSignature": "Optional String returned by lower-level AMSMescal signature methods",
                ],
                "next": "perform this SAP signing operation on a host-side AMS/FairPlay capability source and return replacement headers or signed setup data",
            ],
        ]
    }

    private static func fakeAMSSignSAPSetupResponse(payload: [String: Any], source: String) -> [String: Any] {
        [
            "v": protocolVersion,
            "t": "auth_broker_response",
            "ok": true,
            "kind": "ams_sign_sap_setup",
            "stage": "fake",
            "msg": "fake AMS SAP setup signing response for end-to-end broker testing",
            "data": [
                "source": source,
                "payload_keys": Array(payload.keys).sorted(),
                "headers": [
                    "X-Apple-MD": "fake-md",
                    "X-Apple-MD-M": "fake-md-m",
                    "X-Apple-MD-RINFO": "17106176",
                    "X-Apple-MD-LU": "fake-lu",
                    "X-VPhone-Apple-Emulator": "1",
                ],
                "mescalSignature": "fake-mescal-signature",
            ],
        ]
    }

    private static func handleAMSSignSAPSetupWithEmulator(baseURL: String, payload: [String: Any]) -> [String: Any] {
        guard
            let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/signSapSetup"),
            let body = try? JSONSerialization.data(withJSONObject: payload)
        else {
            return fakeAMSSignSAPSetupResponse(payload: payload, source: "emulator-url-invalid")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        let result = HTTPResultBox()
        URLSession.shared.dataTask(with: request) { data, _, error in
            result.set(data: data, error: error)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        let (responseData, responseError) = result.get()

        guard
            responseError == nil,
            let responseData,
            let emulatorResponse = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        else {
            return [
                "v": protocolVersion,
                "t": "auth_broker_response",
                "ok": false,
                "kind": "ams_sign_sap_setup",
                "stage": "emulator_error",
                "msg": responseError?.localizedDescription ?? "apple emulator did not return JSON",
                "data": [
                    "payload_keys": Array(payload.keys).sorted(),
                    "emulator_url": url.absoluteString,
                ],
            ]
        }

        return [
            "v": protocolVersion,
            "t": "auth_broker_response",
            "ok": true,
            "kind": "ams_sign_sap_setup",
            "stage": "fake_emulator",
            "msg": "fake AMS SAP setup signing response from Apple emulator",
            "data": emulatorResponse,
        ]
    }

    // MARK: - Framing

    private static func readMessage(fd: Int32) -> [String: Any]? {
        var header: UInt32 = 0
        guard readFully(fd: fd, buf: &header, count: 4) else { return nil }
        let length = Int(UInt32(bigEndian: header))
        guard length > 0, length <= 4 * 1024 * 1024 else { return nil }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { buf.deallocate() }
        guard readFully(fd: fd, buf: buf, count: length) else { return nil }
        let data = Data(bytes: buf, count: length)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @discardableResult
    private static func writeMessage(fd: Int32, dict: [String: Any]) -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        var header = UInt32(json.count).bigEndian
        let headerOK = withUnsafeBytes(of: &header) { buf in
            writeFully(fd: fd, buf: buf.baseAddress!, count: 4)
        }
        guard headerOK else { return false }
        return json.withUnsafeBytes { buf in
            writeFully(fd: fd, buf: buf.baseAddress!, count: json.count)
        }
    }

    private static func readFully(fd: Int32, buf: UnsafeMutableRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = read(fd, buf.advanced(by: offset), count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private static func writeFully(fd: Int32, buf: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = write(fd, buf.advanced(by: offset), count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
