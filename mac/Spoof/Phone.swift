// Talks to the iPhone: through Xcode's devicectl where this Mac has it, or the bundled helper.

import AppKit
import CoreLocation
import Foundation

struct PhoneInfo: Equatable, Identifiable {
    let name: String
    let udid: String
    var wired = true
    var issue: Setup?
    var id: String { udid }
}

/// What still has to happen before Spoof can move a phone.
enum Setup: Error, Equatable {
    case unreachable(String)
    case trust(String)
    case developerMode(String)

    var title: String {
        switch self {
        case .unreachable: "Spoof can't look for iPhones"
        case .trust(let phone): "Tap Trust on \(phone)"
        case .developerMode(let phone): "Turn on Developer Mode on \(phone)"
        }
    }

    var detail: String {
        switch self {
        case .unreachable(let why): why
        case .trust: "Then enter the phone's passcode."
        case .developerMode: "Settings > Privacy & Security > Developer Mode, then restart the phone."
        }
    }

    /// The phone pill's text while this is in the way.
    var pill: String? {
        switch self {
        case .unreachable: nil
        case .trust(let phone), .developerMode(let phone): phone
        }
    }
}

/// Finds a current Xcode, if this Mac has one. It isn't needed: without it the bundled helper does
/// the same job. devicectl is run directly because xcrun opens the Command Line Tools installer on
/// a Mac with no developer tools.
enum Xcode {
    static let minimum = 27

    static func developerDir() -> String? {
        let fm = FileManager.default
        if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], fm.isExecutableFile(atPath: dir + "/usr/bin/devicectl") {
            return dir
        }
        let installed = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .compactMap { url -> (dir: String, version: String)? in
                guard let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
                return (url.path + "/Contents/Developer", v)
            }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        guard let newest = installed.first, (Int(newest.version.prefix { $0 != "." }) ?? 0) >= minimum,
              fm.isExecutableFile(atPath: newest.dir + "/usr/bin/devicectl") else { return nil }
        return newest.dir
    }
}

/// The bundled helper (helper/spoof_helper.py), running for as long as Spoof does.
/// One JSON object per line each way, matched up by "id".
final class Helper: @unchecked Sendable {
    static let shared = Helper()
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    private var nextID = 1
    private var buffer = Data()

    private static var tool: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spoof-helper") }

    func send(_ request: [String: Any], seconds: Double = 60) async -> [String: Any] {
        await withCheckedContinuation { cont in
            lock.lock()
            defer { lock.unlock() }
            guard startIfNeeded() else {
                cont.resume(returning: ["ok": false, "error": "The helper is missing from Spoof.app. Download Spoof again."])
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = cont
            var line = (try? JSONSerialization.data(withJSONObject: request.merging(["id": id]) { $1 })) ?? Data()
            line.append(0x0A)
            input?.write(line)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finish(id, ["ok": false, "error": "The iPhone didn't answer in time."])
            }
        }
    }

    private func finish(_ id: Int, _ reply: [String: Any]) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(returning: reply)
    }

    /// Call with the lock held.
    private func startIfNeeded() -> Bool {
        if process?.isRunning == true { return true }
        guard FileManager.default.isExecutableFile(atPath: Self.tool.path) else { return false }
        // Approving Spoof in Privacy & Security covers the app, not the files inside it.
        let clean = Process()
        clean.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        clean.arguments = ["-d", "com.apple.quarantine", Self.tool.path]
        try? clean.run()
        clean.waitUntilExit()

        let p = Process(), toHelper = Pipe(), fromHelper = Pipe()
        p.executableURL = Self.tool
        p.standardInput = toHelper
        p.standardOutput = fromHelper
        p.standardError = FileHandle.nullDevice
        fromHelper.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData)
        }
        p.terminationHandler = { [weak self] _ in self?.died() }
        guard (try? p.run()) != nil else { return false }
        process = p
        input = toHelper.fileHandleForWriting
        buffer = Data()
        return true
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<end])
            buffer = Data(buffer[buffer.index(after: end)...])
        }
        lock.unlock()
        for line in lines {
            guard let reply = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = reply["id"] as? Int else { continue }
            finish(id, reply)
        }
    }

    private func died() {
        lock.lock()
        let waiting = pending
        pending = [:]
        process = nil
        lock.unlock()
        for cont in waiting.values { cont.resume(returning: ["ok": false, "error": "The helper stopped. Try again."]) }
    }
}

enum Phone {
    /// Set by each scan: the helper whenever devicectl isn't there or isn't working.
    nonisolated(unsafe) private static var useHelper = true

    private static func viaHelper(_ request: [String: Any]) async -> String? {
        let reply = await Helper.shared.send(request)
        return reply["ok"] as? Bool == true ? nil : reply["error"] as? String ?? "The helper failed."
    }

    static func run(_ args: [String]) async -> (ok: Bool, output: String) {
        guard let dir = Xcode.developerDir() else { return (false, "no devicectl") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: dir + "/usr/bin/devicectl")
                p.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": dir]) { $1 }
                // A phone on patchy Wi-Fi can hang a call; give up and let the caller retry.
                p.arguments = args + (args.first == "device" ? ["--timeout", "20"] : [])
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: (false, "\(error)")); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus == 0, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    private static func scanWithHelper() async -> Result<[PhoneInfo], Setup> {
        let reply = await Helper.shared.send(["op": "scan"], seconds: 30)
        guard reply["ok"] as? Bool == true, let found = reply["phones"] as? [[String: Any]] else {
            return .failure(.unreachable(reply["error"] as? String ?? "The helper failed."))
        }
        let phones = found.compactMap { d -> PhoneInfo? in
            guard let udid = d["udid"] as? String else { return nil }
            let name = d["name"] as? String ?? "iPhone"
            let issue: Setup? = switch d["issue"] as? String {
            case "trust": .trust(name)
            case "developerMode": .developerMode(name)
            default: nil
            }
            return PhoneInfo(name: name, udid: udid, wired: d["wired"] as? Bool ?? false, issue: issue)
        }
        return .success(phones.filter(\.wired) + phones.filter { !$0.wired })
    }

    /// Every physical iPhone that is plugged in or reachable over Wi-Fi, plugged-in ones first.
    /// A failure rather than an empty list when devicectl itself failed, so a hiccup doesn't look
    /// like every phone leaving.
    static func scan() async -> Result<[PhoneInfo], Setup> {
        let file = NSTemporaryDirectory() + "spoof-devices.json"
        guard Xcode.developerDir() != nil,
              await run(["list", "devices", "-q", "-j", file]).ok,
              let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devs = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            useHelper = true
            return await scanWithHelper()
        }
        useHelper = false
        var phones: [PhoneInfo] = []
        for d in devs {
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["reality"] as? String == "physical", hw["platform"] as? String == "iOS",
                  let transport = conn["transportType"] as? String, let udid = hw["udid"] as? String else { continue }
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let name = props["name"] as? String ?? "iPhone"
            var issue: Setup?
            if conn["pairingState"] as? String == "unpaired" {
                issue = .trust(name)
            } else if props["developerModeStatus"] as? String == "disabled" {
                issue = .developerMode(name)
            }
            phones.append(PhoneInfo(name: name, udid: udid, wired: transport == "wired", issue: issue))
        }
        return .success(phones.filter(\.wired) + phones.filter { !$0.wired })
    }

    static func set(_ udid: String, _ c: CLLocationCoordinate2D) async -> String? {
        if useHelper { return await viaHelper(["op": "set", "udid": udid, "lat": c.latitude, "lon": c.longitude]) }
        // `=` form: devicectl would read a bare negative number as a flag.
        return failure(await run(["device", "simulate", "location", "coordinate", "-d", udid,
                           "--latitude=\(c.latitude)", "--longitude=\(c.longitude)"]))
    }

    static func route(_ udid: String, _ points: [CLLocationCoordinate2D], speed: Double) async -> String? {
        if useHelper {
            return await viaHelper(["op": "route", "udid": udid, "speed": speed, "points": points.map { [$0.latitude, $0.longitude] }])
        }
        let route: [String: Any] = [
            "mode": "interval", "interval": 1.0, "speed": speed,
            "waypoints": points.map { ["latitude": $0.latitude, "longitude": $0.longitude] },
        ]
        let file = NSTemporaryDirectory() + "spoof-route.json"
        do {
            try JSONSerialization.data(withJSONObject: route).write(to: URL(fileURLWithPath: file))
        } catch { return "couldn't write the route file: \(error.localizedDescription)" }
        return failure(await run(["device", "simulate", "location", "route", "-d", udid, "--route-file", file]))
    }

    static func clear(_ udid: String) async -> String? {
        if useHelper { return await viaHelper(["op": "clear", "udid": udid]) }
        return failure(await run(["device", "simulate", "location", "clear", "-d", udid]))
    }

    /// nil on success, otherwise the most useful line of devicectl's output.
    private static func failure(_ r: (ok: Bool, output: String)) -> String? {
        if r.ok { return nil }
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { $0.hasPrefix("Error") || $0.contains("error") } ?? lines.last ?? "devicectl failed"
    }
}
