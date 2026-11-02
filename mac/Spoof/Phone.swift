// Talks to the plugged-in iPhone through Xcode's devicectl, same calls as the spoof CLI.

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
    case xcodeMissing
    case xcodeOld(String)
    case xcodeNotReady(String)
    case trust(String)
    case developerMode(String)

    var title: String {
        switch self {
        case .xcodeMissing: "Spoof needs Xcode"
        case .xcodeOld: "Spoof needs Xcode \(Xcode.minimum) or newer"
        case .xcodeNotReady: "Xcode isn't ready"
        case .trust(let phone): "Tap Trust on \(phone)"
        case .developerMode(let phone): "Turn on Developer Mode on \(phone)"
        }
    }

    var detail: String {
        switch self {
        case .xcodeMissing: "It's free. Install it, then open it once."
        case .xcodeOld(let version): "This Mac has Xcode \(version)."
        case .xcodeNotReady(let why): "Open it once and finish its setup. \(why)"
        case .trust: "Then enter the phone's passcode."
        case .developerMode: "Settings > Privacy & Security > Developer Mode, then restart the phone."
        }
    }

    var action: (label: String, url: URL)? {
        switch self {
        case .xcodeMissing: ("Get Xcode", Xcode.store)
        case .xcodeOld: ("Update Xcode", Xcode.store)
        case .xcodeNotReady: Xcode.app.map { ("Open Xcode", $0) }
        case .trust, .developerMode: nil
        }
    }

    /// The phone pill's text while this is in the way.
    var pill: String? {
        switch self {
        case .xcodeMissing, .xcodeOld, .xcodeNotReady: nil
        case .trust(let phone), .developerMode(let phone): phone
        }
    }
}

/// Finds devicectl, which only ships inside Xcode.app. xcrun can't be trusted to: with no developer
/// tools it opens the Command Line Tools installer, and pointed at those tools it can't see devicectl.
enum Xcode {
    static let minimum = 27
    static let store = URL(string: "macappstore://apps.apple.com/app/id497799835")!

    static var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") }

    static func developerDir() -> Result<String, Setup> {
        let fm = FileManager.default
        if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], fm.isExecutableFile(atPath: dir + "/usr/bin/devicectl") {
            return .success(dir)
        }
        let installed = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .compactMap { url -> (dir: String, version: String)? in
                guard let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
                return (url.path + "/Contents/Developer", v)
            }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        guard let newest = installed.first else { return .failure(.xcodeMissing) }
        guard (Int(newest.version.prefix { $0 != "." }) ?? 0) >= minimum else { return .failure(.xcodeOld(newest.version)) }
        return .success(newest.dir)
    }
}

enum Phone {
    static func run(_ args: [String]) async -> (ok: Bool, output: String) {
        guard case .success(let dir) = Xcode.developerDir() else { return (false, Setup.xcodeMissing.title) }
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

    /// Every physical iPhone that is plugged in or reachable over Wi-Fi, plugged-in ones first.
    /// A failure rather than an empty list when devicectl itself failed, so a hiccup doesn't look
    /// like every phone leaving.
    static func scan() async -> Result<[PhoneInfo], Setup> {
        if case .failure(let setup) = Xcode.developerDir() { return .failure(setup) }
        let file = NSTemporaryDirectory() + "spoof-devices.json"
        let list = await run(["list", "devices", "-q", "-j", file])
        guard list.ok,
              let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devs = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            return .failure(.xcodeNotReady(failure(list) ?? ""))
        }
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
        // `=` form: devicectl would read a bare negative number as a flag.
        failure(await run(["device", "simulate", "location", "coordinate", "-d", udid,
                           "--latitude=\(c.latitude)", "--longitude=\(c.longitude)"]))
    }

    static func route(_ udid: String, _ points: [CLLocationCoordinate2D], speed: Double) async -> String? {
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
        failure(await run(["device", "simulate", "location", "clear", "-d", udid]))
    }

    /// nil on success, otherwise the most useful line of devicectl's output.
    private static func failure(_ r: (ok: Bool, output: String)) -> String? {
        if r.ok { return nil }
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { $0.hasPrefix("Error") || $0.contains("error") } ?? lines.last ?? "devicectl failed"
    }
}
