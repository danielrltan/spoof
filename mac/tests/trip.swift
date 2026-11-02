import CoreLocation
import Foundation

@main
struct TripTest {
    @MainActor static func main() async {
        let m = AppModel()
        m.phone = try? await Phone.scan().get().first
        guard m.phone != nil else { print("no phone"); return }
        m.current = Place(name: "Start", coord: .init(latitude: 37.33182, longitude: -122.03118))
        m.stops = [
            Stop(place: Place(name: "Middle", coord: .init(latitude: 37.3230, longitude: -122.0322)), pace: .drive, stayMinutes: 0.5),
            Stop(place: Place(name: "End", coord: .init(latitude: 37.3238, longitude: -122.0310)), pace: .walk),
        ]
        await m.startTrip()
        guard let r = m.run else { print("no run:", m.error ?? "?"); return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"; f.timeZone = TimeZone(identifier: "UTC")
        for (i, s) in r.steps.enumerated() {
            let at = f.string(from: r.base.addingTimeInterval(r.offsets[i]))
            switch s {
            case .move(let p, let leg): print("STEP \(at) leg\(leg) move \(Int(p.length))m @ \(Int((p.speed * 3.6).rounded())) km/h limit \(p.limit.map { "\(Int($0 * 3.6))" } ?? "-")")
            case .park(_, let sec, let leg): print("STEP \(at) leg\(leg) park \(Int(sec))s")
            }
        }
        print("END  \(f.string(from: r.base.addingTimeInterval(r.total)))")
        fflush(stdout)
        while m.run != nil { try? await Task.sleep(for: .seconds(1)) }
        print("finished; current =", m.current?.name ?? "nil", "error =", m.error ?? "none")
    }
}
