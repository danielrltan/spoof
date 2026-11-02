// Road routes and speed profiles. Drives come from Valhalla (OpenStreetMap), which reports
// the posted limit of every road; walks and rides come from MapKit at a steady pace.

import CoreLocation
import Foundation
import MapKit

enum Pace: String, CaseIterable, Identifiable, Codable {
    case walk, bike, drive
    var id: String { rawValue }
    /// Steady speed for walks and rides, m/s. Drives use road limits instead.
    var speed: Double { switch self { case .walk: 1.4; case .bike: 5; case .drive: 13 } }
    var icon: String { switch self { case .walk: "figure.walk"; case .bike: "bicycle"; case .drive: "car.fill" } }
    var verb: String { switch self { case .walk: "Walking"; case .bike: "Cycling"; case .drive: "Driving" } }
}

/// A road route with a target speed (and the posted limit, when known) for each segment.
struct RoadPath {
    let points: [CLLocationCoordinate2D]
    let target: [Double]    // m/s, per segment
    let limit: [Double?]    // m/s, per segment
    let cumulative: [Double]

    init(points: [CLLocationCoordinate2D], target: [Double], limit: [Double?]) {
        self.points = points
        self.target = target
        self.limit = limit
        var sum = 0.0, acc = [0.0]
        for (a, b) in zip(points, points.dropFirst()) {
            sum += a.distance(to: b)
            acc.append(sum)
        }
        cumulative = acc
    }

    var length: Double { cumulative.last ?? 0 }
}

/// One devicectl route command: constant speed along some points.
struct Piece {
    var points: [CLLocationCoordinate2D]
    var speed: Double       // m/s
    var limit: Double?      // m/s, posted limit on this stretch
    var length: Double
    var duration: Double { length / speed }

    func point(after meters: Double) -> CLLocationCoordinate2D {
        var left = max(0, meters)
        for (a, b) in zip(points, points.dropFirst()) {
            let d = a.distance(to: b)
            if left <= d, d > 0 { return a.lerp(b, left / d) }
            left -= d
        }
        return points.last!
    }

    /// The part still ahead after `meters`.
    func remainder(after meters: Double) -> Piece {
        var left = max(0, meters), out: [CLLocationCoordinate2D] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let d = a.distance(to: b)
            if out.isEmpty {
                if left <= d, d > 0 { out = [a.lerp(b, left / d), b] } else { left -= d }
            } else {
                out.append(b)
            }
        }
        if out.count < 2 { out = [points.last!, points.last!] }
        return Piece(points: out, speed: speed, limit: limit, length: max(0, length - meters))
    }
}

enum Routing {
    static func route(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ pace: Pace) async throws -> RoadPath {
        switch pace {
        case .drive:
            if let p = try? await valhalla(a, b) { return p }
            let mk = try await mapKit(a, b, .automobile)
            // No limits from MapKit: cruise at Apple's own average for the route.
            let avg = mk.time > 0 ? mk.path.length / mk.time : 13
            return RoadPath(points: mk.path.points, target: mk.path.target.map { _ in avg }, limit: mk.path.limit)
        case .bike:
            if let mk = try? await mapKit(a, b, .cycling) { return mk.path }
            return (try? await mapKit(a, b, .walking))?.path ?? straight(a, b, pace)
        case .walk:
            return (try? await mapKit(a, b, .walking))?.path ?? straight(a, b, pace)
        }
    }

    private static func straight(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ pace: Pace) -> RoadPath {
        RoadPath(points: [a, b], target: [pace.speed], limit: [nil])
    }

    private static func mapKit(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                               _ type: MKDirectionsTransportType) async throws -> (path: RoadPath, time: Double) {
        let req = MKDirections.Request()
        req.source = MKMapItem(location: CLLocation(latitude: a.latitude, longitude: a.longitude), address: nil)
        req.destination = MKMapItem(location: CLLocation(latitude: b.latitude, longitude: b.longitude), address: nil)
        req.transportType = type
        guard let route = try await MKDirections(request: req).calculate().routes.first else {
            throw URLError(.cannotFindHost)
        }
        let line = route.polyline
        var pts = [CLLocationCoordinate2D](repeating: .init(), count: line.pointCount)
        line.getCoordinates(&pts, range: NSRange(location: 0, length: line.pointCount))
        let speed = type == .cycling ? Pace.bike.speed : Pace.walk.speed
        let n = max(0, pts.count - 1)
        return (RoadPath(points: pts, target: Array(repeating: speed, count: n), limit: Array(repeating: nil, count: n)),
                route.expectedTravelTime)
    }

    // MARK: Valhalla

    private static let valhallaHost = URL(string: "https://valhalla1.openstreetmap.de/")!

    /// Default limits (km/h) by road class when OpenStreetMap has no posted limit.
    private static let classDefault: [String: Double] = [
        "motorway": 100, "trunk": 80, "primary": 60, "secondary": 50, "tertiary": 50,
        "unclassified": 50, "residential": 40, "service_other": 20,
    ]

    private static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: valhallaHost.appendingPathComponent(path), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Spoof/1.0 (+https://github.com/danielrltan/spoof)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return json
    }

    private static func valhalla(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) async throws -> RoadPath {
        let route = try await post("route", [
            "locations": [["lat": a.latitude, "lon": a.longitude], ["lat": b.latitude, "lon": b.longitude]],
            "costing": "auto",
        ])
        guard let legs = (route["trip"] as? [String: Any])?["legs"] as? [[String: Any]],
              let shape = legs.first?["shape"] as? String else { throw URLError(.cannotParseResponse) }

        let trace = try await post("trace_attributes", [
            "encoded_polyline": shape, "costing": "auto", "shape_match": "edge_walk",
            "filters": ["action": "include", "attributes": [
                "shape", "edge.speed_limit", "edge.speed", "edge.road_class",
                "edge.begin_shape_index", "edge.end_shape_index",
            ]],
        ])
        guard let traceShape = trace["shape"] as? String, let edges = trace["edges"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        let pts = decodePolyline6(traceShape)
        guard pts.count >= 2, pts[0].distance(to: a) < 500 else { throw URLError(.cannotParseResponse) }

        var target = [Double](repeating: 13, count: pts.count - 1)
        var limit = [Double?](repeating: nil, count: pts.count - 1)
        for e in edges {
            guard let lo = (e["begin_shape_index"] as? NSNumber)?.intValue,
                  let hi = (e["end_shape_index"] as? NSNumber)?.intValue else { continue }
            let posted = (e["speed_limit"] as? NSNumber)?.doubleValue ?? 0
            let fallback = classDefault[e["road_class"] as? String ?? ""] ?? (e["speed"] as? NSNumber)?.doubleValue ?? 50
            let kmh = posted > 0 ? posted : fallback
            for i in max(0, lo)..<min(hi, target.count) {
                target[i] = kmh / 3.6
                limit[i] = posted > 0 ? posted / 3.6 : nil
            }
        }
        return RoadPath(points: pts, target: target, limit: limit)
    }

    static func decodePolyline6(_ s: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lon = 0, out: [CLLocationCoordinate2D] = []
        func next() -> Int? {
            var result = 0, shift = 0, b = 0
            repeat {
                guard i < bytes.count else { return nil }
                b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }
        while i < bytes.count, let dlat = next(), let dlon = next() {
            lat += dlat
            lon += dlon
            out.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6))
        }
        return out
    }
}

// MARK: speed profile

enum Profile {
    static let accel = 2.0      // m/s², an unhurried start
    static let brake = 2.5      // m/s²
    static let sample = 10.0    // metres between profile samples
    static let minPiece = 3.0   // seconds; the phone updates once a second, shorter pieces may never show

    /// Split a route into constant-speed pieces. `scale` multiplies every target speed (for custom durations).
    static func pieces(_ path: RoadPath, pace: Pace, scale: Double = 1) -> [Piece] {
        guard path.points.count >= 2, path.length > 0.5 else { return [] }
        if pace != .drive {
            let v = pace.speed * scale
            return [Piece(points: path.points, speed: v, limit: nil, length: path.length)]
        }

        // Resample so every stretch of road is at most `sample` metres, keeping each original vertex.
        var pts: [CLLocationCoordinate2D] = [path.points[0]]
        var cap: [Double] = [0]           // speed cap at each sample (0 at the ends: start and stop)
        var segOf: [Int] = []             // original segment each sample interval lies on
        for s in 0..<(path.points.count - 1) {
            let a = path.points[s], b = path.points[s + 1]
            let d = a.distance(to: b)
            let n = max(1, Int((d / sample).rounded(.up)))
            for k in 1...n {
                pts.append(a.lerp(b, Double(k) / Double(n)))
                segOf.append(s)
                let v = path.target[s] * scale
                if k == n, s + 1 < path.points.count - 1 {
                    let next = path.target[s + 1] * scale
                    cap.append(min(v, next, corner(path.points[s], b, path.points[s + 2])))
                } else {
                    cap.append(v)
                }
            }
        }
        cap[cap.count - 1] = 0

        var dist = [Double](repeating: 0, count: pts.count - 1)
        for i in 0..<dist.count { dist[i] = pts[i].distance(to: pts[i + 1]) }

        // Forward pass (acceleration), backward pass (braking).
        var v = cap
        v[0] = 0
        for i in 0..<dist.count { v[i + 1] = min(v[i + 1], (v[i] * v[i] + 2 * accel * dist[i]).squareRoot()) }
        for i in stride(from: dist.count - 1, through: 0, by: -1) {
            v[i] = min(v[i], (v[i + 1] * v[i + 1] + 2 * brake * dist[i]).squareRoot())
        }

        // Group sample intervals into pieces of roughly constant speed, splitting where the posted limit changes.
        var out: [Piece] = []
        var cur: [CLLocationCoordinate2D] = [pts[0]], len = 0.0, time = 0.0, startV = -1.0
        var lim: Double?
        func close() {
            guard len > 0, time > 0 else { return }
            out.append(Piece(points: cur, speed: len / time, limit: lim, length: len))
            cur = [cur.last!]
            len = 0
            time = 0
            startV = -1
        }
        for i in 0..<dist.count {
            let iv = max(0.5, (v[i] + v[i + 1]) / 2)
            let segLimit = path.limit[segOf[i]]
            if startV >= 0, time >= minPiece, abs(iv - startV) > 1.0 || segLimit != lim { close() }
            if startV < 0 { startV = iv; lim = segLimit }
            cur.append(pts[i + 1])
            len += dist[i]
            time += dist[i] / iv
        }
        if time < minPiece, var last = out.popLast() {
            // Too short to show on the phone: fold into the piece before it.
            let total = last.duration + time
            last.points += cur.dropFirst()
            last.length += len
            last.speed = last.length / total
            out.append(last)
        } else {
            close()
        }
        return out
    }

    /// Speed allowed through a turn at `b`, from the angle between a→b and b→c.
    private static func corner(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Double {
        guard a.distance(to: b) > 4, b.distance(to: c) > 4 else { return .infinity }
        var turn = abs(c.bearing(from: b) - b.bearing(from: a))
        if turn > 180 { turn = 360 - turn }
        switch turn {
        case ..<35: return .infinity
        case ..<70: return 35 / 3.6
        case ..<110: return 22 / 3.6
        default: return 15 / 3.6
        }
    }
}

extension CLLocationCoordinate2D {
    func distance(to o: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: o.latitude, longitude: o.longitude))
    }

    func lerp(_ o: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude + (o.latitude - latitude) * t, longitude: longitude + (o.longitude - longitude) * t)
    }

    /// Degrees clockwise from north, heading from `o` to self.
    func bearing(from o: CLLocationCoordinate2D) -> Double {
        let p1 = o.latitude * .pi / 180, p2 = latitude * .pi / 180, dl = (longitude - o.longitude) * .pi / 180
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
