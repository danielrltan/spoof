import CoreLocation
import Foundation

let a = CLLocationCoordinate2D(latitude: 37.33182, longitude: -122.03118)
let b = CLLocationCoordinate2D(latitude: 37.33470, longitude: -122.00890)
let path = try await Routing.route(a, b, .drive)
print("points", path.points.count, "length", Int(path.length), "first-off", Int(path.points[0].distance(to: a)), "m")
let pieces = Profile.pieces(path, pace: .drive)
var t = 0.0
for p in pieces {
    print(String(format: "t=%6.1fs  %5.0f m  %4.0f km/h  limit %@  %2d pts", t, p.length, p.speed * 3.6,
                 p.limit.map { String(format: "%.0f", $0 * 3.6) } ?? "-", p.points.count))
    t += p.duration
}
print(String(format: "total %.0f s (%.1f min), %d pieces, max over-limit: %@", t, t / 60, pieces.count,
             pieces.contains { p in p.limit.map { p.speed > $0 * 1.03 } ?? false } ? "YES" : "none"))
// Custom 15 min on the same leg
let slow = Profile.pieces(path, pace: .drive, scale: 0.5).reduce(0) { $0 + $1.duration }
print(String(format: "scale 0.5 -> %.1f min", slow / 60))
// Split check
let mid = pieces[pieces.count / 2]
let r = mid.remainder(after: mid.length / 3)
print(String(format: "remainder: %.0f of %.0f m, start matches point: %.2f m", r.length, mid.length, r.points[0].distance(to: mid.point(after: mid.length / 3))))
