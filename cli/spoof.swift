// spoof: set a connected iPhone's location from the Mac via `xcrun devicectl`.
// Needs the phone paired with this Mac and Developer Mode on.

import CoreLocation
import Foundation
import MapKit

let statePath = NSHomeDirectory() + "/.spoof-state.json"
let speeds: [String: Double] = ["walk": 1.4, "bike": 5.0, "drive": 13.0]

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func usage() -> Never {
    print("""
    usage:
      spoof set <place | lat,lon>             pin the phone at one spot
      spoof go <from> <to> [walk|bike|drive]  move along the road route (default walk)
      spoof clear                             back to real GPS
      spoof status                            what spoof last set
      spoof devices                           list phones devicectl can see

    options: --device <name|udid>   --dry-run (print the devicectl call, don't run it)
    """)
    exit(2)
}

// MARK: devicectl

@discardableResult
func run(_ args: [String], capture: Bool = false) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["devicectl"] + args
    let pipe = Pipe()
    if capture { p.standardOutput = pipe }
    do { try p.run() } catch { die("could not run xcrun: \(error)") }
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct Phone { let name: String; let udid: String; let state: String }

func phones() -> [Phone] {
    let (code, out) = run(["list", "devices", "-q", "-j", "-"], capture: true)
    guard code == 0, let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
          let devs = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
    return devs.compactMap { d in
        let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
        guard hw["reality"] as? String == "physical", hw["platform"] as? String == "iOS" else { return nil }
        let props = d["deviceProperties"] as? [String: Any] ?? [:]
        let conn = d["connectionProperties"] as? [String: Any] ?? [:]
        return Phone(name: props["name"] as? String ?? "?",
                     udid: hw["udid"] as? String ?? (d["identifier"] as? String ?? "?"),
                     state: conn["tunnelState"] as? String ?? "?")
    }
}

func pickDevice(_ wanted: String?) -> String {
    if let wanted { return wanted }
    let list = phones()
    if list.isEmpty { die("no physical iPhone paired with this Mac. Plug it in, unlock, tap Trust.") }
    if list.count > 1 { die("several phones; pass --device <name|udid>:\n" + list.map { "  \($0.name)  \($0.udid)" }.joined(separator: "\n")) }
    return list[0].udid
}

func devicectl(_ args: [String], dryRun: Bool) {
    if dryRun { print("xcrun devicectl " + args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")); return }
    let (code, _) = run(args)
    if code != 0 {
        die("devicectl failed. Check: phone unlocked and connected, Developer Mode on (Settings > Privacy & Security), and Xcode has prepared the device once.")
    }
}

// MARK: places and routes

func wait<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    body { result = $0 }
    while result == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return result!
}

func resolve(_ text: String) -> CLLocationCoordinate2D {
    let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) {
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { die("coordinates out of range: \(text)") }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    let req = MKLocalSearch.Request()
    req.naturalLanguageQuery = text
    let item: MKMapItem?? = wait { done in
        MKLocalSearch(request: req).start { resp, _ in done(resp?.mapItems.first) }
    }
    guard let found = item ?? nil else { die("couldn't find a place called \"\(text)\"") }
    let addr = found.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? ""
    print("  \"\(text)\" matched: \(found.name ?? "?")\(addr.isEmpty ? "" : ", " + addr)")
    return found.location.coordinate
}

func roadRoute(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, walking: Bool) -> [CLLocationCoordinate2D] {
    let req = MKDirections.Request()
    req.source = MKMapItem(location: CLLocation(latitude: a.latitude, longitude: a.longitude), address: nil)
    req.destination = MKMapItem(location: CLLocation(latitude: b.latitude, longitude: b.longitude), address: nil)
    req.transportType = walking ? .walking : .automobile
    let route: MKRoute? = wait { done in
        MKDirections(request: req).calculate { resp, _ in done(resp?.routes.first) }
    }
    guard let line = route?.polyline else {
        print("no road route found; going in a straight line")
        return [a, b]
    }
    var pts = [CLLocationCoordinate2D](repeating: .init(), count: line.pointCount)
    line.getCoordinates(&pts, range: NSRange(location: 0, length: line.pointCount))
    return pts
}

func meters(_ pts: [CLLocationCoordinate2D]) -> Double {
    zip(pts, pts.dropFirst()).reduce(0) {
        $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)
            .distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
    }
}

func fmt(_ c: CLLocationCoordinate2D) -> String { String(format: "%.6f,%.6f", c.latitude, c.longitude) }

func saveState(_ s: [String: Any]) {
    var s = s
    s["at"] = ISO8601DateFormatter().string(from: Date())
    if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: statePath))
    }
}

let clearHint = "real GPS again: spoof clear"

// MARK: main

var args = Array(CommandLine.arguments.dropFirst())
var device: String?
var dryRun = false
if let i = args.firstIndex(of: "--device") {
    guard i + 1 < args.count else { usage() }
    device = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
if let i = args.firstIndex(of: "--dry-run") { dryRun = true; args.remove(at: i) }
guard let cmd = args.first else { usage() }
let rest = Array(args.dropFirst())

switch cmd {
case "devices":
    let list = phones()
    if list.isEmpty { print("no physical iPhones paired") }
    for p in list { print("\(p.name)  \(p.udid)  \(p.state)") }

case "set":
    guard !rest.isEmpty else { usage() }
    let place = rest.joined(separator: " ")
    let c = resolve(place)
    let udid = pickDevice(device)
    devicectl(["device", "simulate", "location", "coordinate", "-d", udid,
               "--latitude=\(c.latitude)", "--longitude=\(c.longitude)"], dryRun: dryRun)
    if !dryRun { saveState(["mode": "set", "place": place, "coord": fmt(c), "device": udid]) }
    print("phone pinned at \(place) (\(fmt(c))). \(clearHint)")

case "go":
    guard rest.count >= 2 else { usage() }
    let how = rest.count >= 3 ? rest[2] : "walk"
    guard let speed = speeds[how] else { die("speed must be walk, bike or drive") }
    let a = resolve(rest[0]), b = resolve(rest[1])
    let pts = roadRoute(a, b, walking: how != "drive")
    let dist = meters(pts)
    let route: [String: Any] = [
        "mode": "interval", "interval": 1.0, "speed": speed,
        "waypoints": pts.map { ["latitude": $0.latitude, "longitude": $0.longitude] },
    ]
    let file = NSTemporaryDirectory() + "spoof-route.json"
    try! JSONSerialization.data(withJSONObject: route).write(to: URL(fileURLWithPath: file))
    let udid = pickDevice(device)
    print(String(format: "%@ → %@: %.1f km, %d points, about %.0f min at %@ pace",
                 rest[0], rest[1], dist / 1000, pts.count, dist / speed / 60, how))
    devicectl(["device", "simulate", "location", "route", "-d", udid, "--route-file", file], dryRun: dryRun)
    if dryRun { break }
    // A finished route keeps reporting its speed, so wait it out and then stand still at the end.
    print("keep the phone plugged in; Ctrl-C leaves it reporting \(how) speed")
    let end = pts.last!
    Thread.sleep(forTimeInterval: dist / speed + 1)
    devicectl(["device", "simulate", "location", "coordinate", "-d", udid,
               "--latitude=\(end.latitude)", "--longitude=\(end.longitude)"], dryRun: false)
    saveState(["mode": "set", "place": rest[1], "coord": fmt(end), "device": udid])
    print("arrived at \(rest[1]). \(clearHint)")

case "clear":
    let udid = pickDevice(device)
    devicectl(["device", "simulate", "location", "clear", "-d", udid], dryRun: dryRun)
    if !dryRun { try? FileManager.default.removeItem(atPath: statePath) }
    print("phone is back on real GPS")

case "status":
    if let d = FileManager.default.contents(atPath: statePath), let s = String(data: d, encoding: .utf8) {
        print("last set by spoof (may have ended since, e.g. route finished or phone rebooted):\n\(s)\n\(clearHint)")
    } else {
        print("spoof hasn't set a location since the last clear")
    }

default:
    usage()
}
