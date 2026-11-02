import CoreLocation
import Foundation
import MapKit
import Observation

struct Place: Equatable {
    var name: String
    var coord: CLLocationCoordinate2D

    static func == (a: Place, b: Place) -> Bool {
        a.name == b.name && a.coord.latitude == b.coord.latitude && a.coord.longitude == b.coord.longitude
    }
}

/// A stop on the trip; `pace` and `minutes` describe the leg that arrives here.
struct Stop: Identifiable, Equatable {
    let id = UUID()
    var place: Place
    var pace: Pace
    var minutes: Double?        // custom leg duration; nil = at the speed limit / normal pace
    var stayMinutes: Double = 0
}

/// A leg ready to play: its route and pieces, or why it isn't ready.
struct Leg {
    var from: Place
    var to: Place
    var pace: Pace
    var path: RoadPath?
    var failed = false
    var pieces: [Piece] = []

    var length: Double { pieces.reduce(0) { $0 + $1.length } }
    var duration: Double { pieces.reduce(0) { $0 + $1.duration } }
    var average: Double { duration > 0 ? length / duration : 0 }
    var top: Double { pieces.map(\.speed).max() ?? 0 }
    /// Fastest piece relative to its posted limit, if any piece goes over.
    var over: (speed: Double, limit: Double)? {
        pieces.compactMap { p in p.limit.flatMap { p.speed > $0 * 1.03 ? (p.speed, $0) : nil } }
            .max { $0.0 - $0.1 < $1.0 - $1.1 }
    }
}

/// What the phone is told to do, in order.
enum Step {
    case move(Piece, leg: Int)
    case park(CLLocationCoordinate2D, seconds: Double, leg: Int)

    var duration: Double {
        switch self {
        case .move(let p, _): p.duration
        case .park(_, let s, _): s
        }
    }

    var leg: Int {
        switch self {
        case .move(_, let l), .park(_, _, let l): l
        }
    }
}

struct Run {
    var steps: [Step]
    var offsets: [Double]       // seconds from `base` at which each step starts
    var base: Date
    var legs: [Leg]
    var paused = false
    var planned = false         // started from the trip planner, not a quick Walk/Bike/Drive
    var needsPark = false       // phone vanished mid-piece; park it when it's back
    var cableFree = false       // one steady route the phone plays by itself after unplugging
    var arrivedUnparked = false // trip ended while the phone was out of reach; pin it once it answers

    init(steps: [Step], legs: [Leg], base: Date = .now) {
        self.steps = steps
        self.legs = legs
        self.base = base
        var t = 0.0, o: [Double] = []
        for s in steps { o.append(t); t += s.duration }
        offsets = o
    }

    var total: Double { (offsets.last ?? 0) + (steps.last?.duration ?? 0) }

    func index(at date: Date) -> Int {
        let e = date.timeIntervalSince(base)
        return max(0, (offsets.lastIndex { $0 <= e }) ?? 0)
    }

    /// Position, speed and posted limit at `date`, by the schedule.
    func state(at date: Date) -> (coord: CLLocationCoordinate2D, speed: Double, limit: Double?, leg: Int) {
        if paused {
            switch steps[0] {
            case .park(let c, _, let leg): return (c, 0, nil, leg)
            case .move(let p, let leg): return (p.points[0], 0, p.limit, leg)
            }
        }
        let i = index(at: date)
        let into = max(0, date.timeIntervalSince(base) - offsets[i])
        switch steps[i] {
        case .move(let p, let leg):
            if paused || into >= p.duration { return (p.point(after: p.length), 0, p.limit, leg) }
            return (p.point(after: into * p.speed), p.speed, p.limit, leg)
        case .park(let c, _, let leg):
            return (c, 0, nil, leg)
        }
    }
}

@MainActor @Observable
final class AppModel {
    /// The chosen phone, while it's reachable.
    var phone: PhoneInfo?
    var phones: [PhoneInfo] = []
    var checkedPhone = false
    /// What's in the way of using a phone at all; nil once there's nothing left to set up.
    var setup: Setup?
    @ObservationIgnored private var scanFailures = 0
    /// The phone this Mac controls. It sticks while that phone is away, so a trip or timer
    /// never jumps to another phone that happens to be plugged in.
    var chosenUDID = UserDefaults.standard.string(forKey: "phone") {
        didSet { UserDefaults.standard.set(chosenUDID, forKey: "phone") }
    }
    var chosenName = UserDefaults.standard.string(forKey: "phoneName") {
        didSet { UserDefaults.standard.set(chosenName, forKey: "phoneName") }
    }
    /// Where the chosen phone is faked to (as last set from this Mac); nil means real GPS.
    var current: Place? {
        didSet { if let u = chosenUDID { spots[u] = current } }
    }
    /// Every phone's faked spot, so switching phones and back still knows which are faked.
    private var spots: [String: Place] = AppModel.loadSpots() {
        didSet { UserDefaults.standard.set(spots.mapValues { ["name": $0.name, "lat": $0.coord.latitude, "lon": $0.coord.longitude] }, forKey: "spots") }
    }
    var selected: Place?
    var busy = false
    var error: String?

    // Trip plan
    var start: Place?           // nil = wherever the phone is
    var stops: [Stop] = []
    var lastPace: Pace = .drive
    /// Trips play as one steady-speed route so the cable can come out once they start.
    var cableFree = UserDefaults.standard.bool(forKey: "cableFree") {
        didSet { UserDefaults.standard.set(cableFree, forKey: "cableFree") }
    }
    private var routes: [String: RoadPath] = [:]
    private var failedRoutes: Set<String> = []
    private var routing: Set<String> = []
    @ObservationIgnored private var fitted: [String: [Piece]] = [:]

    // Playback
    var run: Run?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var awake: NSObjectProtocol?

    /// When each phone goes back to real GPS by itself. The Mac sends the reset, so a phone that's
    /// away then gets it as soon as it's back. Kept across relaunches.
    private var timers = UserDefaults.standard.dictionary(forKey: "timers") as? [String: Date] ?? [:] {
        didSet {
            UserDefaults.standard.set(timers, forKey: "timers")
            holdAwakeForTimer()
        }
    }
    /// The chosen phone's timer.
    var resetAt: Date? {
        get { chosenUDID.flatMap { timers[$0] } }
        set { if let u = chosenUDID { timers[u] = newValue } }
    }
    @ObservationIgnored private var timerAwake: NSObjectProtocol?

    private let statePath = NSHomeDirectory() + "/.spoof-state.json"

    /// This Mac's own location: the plugged-in phone's real spot, for trips started from real GPS.
    var here: CLLocationCoordinate2D?
    @ObservationIgnored private let locator = Locator()

    init() {
        if let u = chosenUDID, let s = spots[u] { current = s } else if spots.isEmpty { loadState() }
        holdAwakeForTimer()
        locator.onFix = { [weak self] c in self?.here = c }
        locator.start()
    }

    func watchPhone() async {
        while !Task.isCancelled {
            switch await Phone.scan() {
            case .success(let found):
                scanFailures = 0
                let all = found.filter { $0.issue == nil }
                if all != phones { phones = all }
                if chosenUDID == nil, let first = all.first { choose(first) }
                let p = all.first { $0.udid == chosenUDID }
                if p != phone { phone = p }
                let issue = p == nil && all.isEmpty ? found.lazy.compactMap(\.issue).first : nil
                if issue != setup { setup = issue }
                checkedPhone = true
            case .failure(let problem):
                // devicectl hiccups now and then; only a repeat means something's wrong.
                scanFailures += 1
                if case .xcodeNotReady = problem, scanFailures < 3 { break }
                if problem != setup { setup = problem }
                checkedPhone = true
            }
            let p = phone
            if let p, run?.needsPark == true, let spot = run?.state(at: .now).coord {
                if await Phone.set(p.udid, spot) == nil { run?.needsPark = false }
            }
            if let p, let r = run, r.arrivedUnparked, let end = r.legs.last?.to {
                if await Phone.set(p.udid, end.coord) == nil { finish(at: end) }
            }
            for (u, t) in timers where t <= .now && phones.contains(where: { $0.udid == u }) {
                if u == chosenUDID {
                    if !busy { await reset() }
                } else if await Phone.clear(u) == nil {
                    timers[u] = nil
                    spots[u] = nil
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Control another phone. Not mid-trip: the trip belongs to the phone it started on.
    func choose(_ p: PhoneInfo) {
        guard run == nil, p.udid != chosenUDID || chosenName != p.name else { return }
        chosenUDID = p.udid
        chosenName = p.name
        current = spots[p.udid]
        phone = phones.first { $0.udid == p.udid }
        error = nil
    }

    private static func loadSpots() -> [String: Place] {
        let raw = UserDefaults.standard.dictionary(forKey: "spots") as? [String: [String: Any]] ?? [:]
        return raw.compactMapValues { d in
            guard let name = d["name"] as? String, let lat = d["lat"] as? Double, let lon = d["lon"] as? Double else { return nil }
            return Place(name: name, coord: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    /// Send the faked spot again, so the phone reports standing still there.
    func pin() async {
        guard let c = current, run == nil else { return }
        await perform { udid in await Phone.set(udid, c.coord) }
    }

    func resetAfter(minutes: Double) {
        resetAt = Date.now.addingTimeInterval(minutes * 60)
    }

    private func holdAwakeForTimer() {
        if !timers.isEmpty, timerAwake == nil {
            timerAwake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                               reason: "Timed return to real GPS")
        } else if timers.isEmpty, let a = timerAwake {
            ProcessInfo.processInfo.endActivity(a)
            timerAwake = nil
        }
    }

    /// Where the phone is right now, as far as this app knows.
    func phoneSpot(at date: Date) -> CLLocationCoordinate2D? {
        run?.state(at: date).coord ?? current?.coord ?? here
    }

    var tripStart: Place? {
        start ?? current.map { Place(name: "Phone's spot", coord: $0.coord) }
            ?? here.map { Place(name: "Your real location", coord: $0) }
    }

    // MARK: planning

    private func key(_ a: Place, _ b: Place, _ pace: Pace) -> String {
        String(format: "%.6f,%.6f>%.6f,%.6f:", a.coord.latitude, a.coord.longitude, b.coord.latitude, b.coord.longitude) + pace.rawValue
    }

    func legs(for stops: [Stop], from first: Place?) -> [Leg] {
        guard var from = first else { return [] }
        return stops.map { s in
            let k = key(from, s.place, s.pace)
            var leg = Leg(from: from, to: s.place, pace: s.pace, path: routes[k], failed: failedRoutes.contains(k))
            if let path = leg.path {
                let fk = k + "|\(s.minutes ?? 0)"
                if let cached = fitted[fk] { leg.pieces = cached } else {
                    leg.pieces = Self.fit(path, s.pace, minutes: s.minutes)
                    fitted[fk] = leg.pieces
                }
            }
            from = s.place
            return leg
        }
    }

    var plannedLegs: [Leg] { legs(for: stops, from: tripStart) }

    /// Pieces for a leg, stretched or squeezed to a custom duration when one is set.
    static func fit(_ path: RoadPath, _ pace: Pace, minutes: Double?) -> [Piece] {
        let natural = Profile.pieces(path, pace: pace)
        guard let m = minutes, m > 0 else { return natural }
        let want = m * 60
        let dur: (Double) -> Double = { s in Profile.pieces(path, pace: pace, scale: s).reduce(0) { $0 + $1.duration } }
        var lo = 0.02, hi = 6.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if dur(mid) > want { lo = mid } else { hi = mid }
        }
        return Profile.pieces(path, pace: pace, scale: (lo + hi) / 2)
    }

    /// Fetch any routes the plan needs (one at a time; Valhalla is a shared public server).
    func fetchRoutes(_ legs: [Leg]) async {
        for leg in legs where leg.path == nil {
            let k = key(leg.from, leg.to, leg.pace)
            guard !routing.contains(k), !failedRoutes.contains(k) else { continue }
            routing.insert(k)
            do { routes[k] = try await Routing.route(leg.from.coord, leg.to.coord, leg.pace) } catch { failedRoutes.insert(k) }
            routing.remove(k)
        }
    }

    func addStop(_ p: Place) {
        if tripStart == nil { start = p; return }
        stops.append(Stop(place: p, pace: stops.last?.pace ?? lastPace))
    }

    // MARK: actions

    func teleport() async {
        guard let place = selected else { return }
        if run != nil { runTask?.cancel(); finish(at: nil) }
        await perform { udid in
            if let e = await Phone.set(udid, place.coord) { return e }
            self.current = place
            self.saveState(place)
            return nil
        }
    }

    /// Straight to the selected place, no planner.
    func travel(_ pace: Pace) async {
        guard let dest = selected, let here = phoneSpot(at: .now) else { return }
        lastPace = pace
        let stop = Stop(place: dest, pace: pace)
        let from = Place(name: "Here", coord: here)
        await fetchRoutes(legs(for: [stop], from: from))
        play(legs(for: [stop], from: from), stays: [0], planned: false)
    }

    func startTrip() async {
        await fetchRoutes(plannedLegs)
        play(plannedLegs, stays: stops.map(\.stayMinutes), planned: true)
    }

    private func play(_ legs: [Leg], stays: [Double], planned: Bool) {
        guard !legs.isEmpty, legs.allSatisfy({ !$0.pieces.isEmpty }) else {
            error = "Couldn't find a route for every leg"
            return
        }
        if cableFree { return playSteady(legs, planned: planned) }
        var steps: [Step] = []
        for (i, leg) in legs.enumerated() {
            steps += leg.pieces.map { .move($0, leg: i) }
            let last = i == legs.count - 1
            steps.append(.park(leg.to.coord, seconds: last ? 0 : stays[i] * 60, leg: i))
        }
        error = nil
        var r = Run(steps: steps, legs: legs)
        r.planned = planned
        begin(r)
    }

    /// The whole trip as one route at its average speed: the phone plays it alone, so the cable can come out.
    private func playSteady(_ legs: [Leg], planned: Bool) {
        var points: [CLLocationCoordinate2D] = []
        for leg in legs {
            for p in leg.pieces { points += points.isEmpty ? p.points : Array(p.points.dropFirst()) }
        }
        let length = legs.reduce(0) { $0 + $1.length }, time = legs.reduce(0) { $0 + $1.duration }
        guard points.count >= 2, length > 0, time > 0 else { error = "Couldn't build the route"; return }
        let piece = Piece(points: points, speed: length / time, limit: nil, length: length)
        let n = points.count - 1
        var whole = Leg(from: legs[0].from, to: legs.last!.to, pace: legs.last!.pace,
                        path: RoadPath(points: points, target: Array(repeating: piece.speed, count: n),
                                       limit: Array(repeating: nil, count: n)))
        whole.pieces = [piece]
        error = nil
        var r = Run(steps: [.move(piece, leg: 0), .park(whole.to.coord, seconds: 0, leg: 0)], legs: [whole])
        r.planned = planned
        r.cableFree = true
        begin(r)
    }

    private func begin(_ r: Run) {
        runTask?.cancel()
        run = r
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "Playing a trip on the iPhone")
        }
        runTask = Task { await loop() }
    }

    private func loop() async {
        guard let r = run else { return }
        for i in r.index(at: .now)..<r.steps.count {
            let wait = r.base.addingTimeInterval(r.offsets[i] - 0.2).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if Task.isCancelled { return }
            let last = i == r.steps.count - 1
            var pinned = false
            if last, case .park(let c, _, _) = r.steps[i], let udid = phone?.udid {
                pinned = await Phone.set(udid, c) == nil
            }
            if last, !pinned, case .park = r.steps[i], let end = r.legs.last?.to {
                // Arrived but the phone didn't answer; it still reports the trip's speed until it's
                // pinned, so watchPhone keeps trying instead of pausing the trip.
                if Task.isCancelled { return }
                run?.arrivedUnparked = true
                current = end
                saveState(end)
                return
            }
            if pinned { if Task.isCancelled { return }; break }
            guard let udid = phone?.udid else { return await lost() }
            let e: String?
            switch r.steps[i] {
            case .move(let p, _): e = await Phone.route(udid, p.points, speed: p.speed)
            case .park(let c, _, _): e = await Phone.set(udid, c)
            }
            if Task.isCancelled { return }
            if e != nil { return await lost() }
        }
        finish(at: r.legs.last!.to)
    }

    private func finish(at place: Place?) {
        run = nil
        runTask = nil
        if let a = awake { ProcessInfo.processInfo.endActivity(a); awake = nil }
        if let place { current = place; saveState(place) }
    }

    /// The phone went away mid-trip: hold the trip where it should be and park it once it's back.
    private func lost() async {
        freeze()
        run?.needsPark = true
        error = "iPhone disconnected. Plug it back in, then Resume"
    }

    /// Stop the schedule at the current moment, keeping what's left of it.
    private func freeze() {
        guard var r = run else { return }
        runTask?.cancel()
        let now = Date.now
        let i = r.index(at: now)
        let into = max(0, now.timeIntervalSince(r.base) - r.offsets[i])
        var rest = Array(r.steps[i...])
        switch rest[0] {
        case .move(let p, let leg):
            rest[0] = .move(p.remainder(after: min(p.length, into * p.speed)), leg: leg)
            let pos = p.point(after: min(p.length, into * p.speed))
            rest.insert(.park(pos, seconds: 0, leg: leg), at: 0)
        case .park(let c, let s, let leg):
            rest[0] = .park(c, seconds: max(0, s - into), leg: leg)
        }
        let planned = r.planned, cableFree = r.cableFree
        r = Run(steps: rest, legs: r.legs, base: now)
        r.paused = true
        r.planned = planned
        r.cableFree = cableFree
        run = r
    }

    func pause() async {
        guard run?.paused == false else { return }
        freeze()
        guard let udid = phone?.udid, let spot = run?.state(at: .now).coord else { return }
        if await Phone.set(udid, spot) != nil { run?.needsPark = true }
    }

    func resume() {
        guard var r = run, r.paused, phone != nil else { return }
        error = nil
        // Drop the zero-length park that marks the pause point.
        if case .park(_, 0, _) = r.steps[0], r.steps.count > 1 { r.steps.removeFirst() }
        var next = Run(steps: r.steps, legs: r.legs)
        next.planned = r.planned
        next.cableFree = r.cableFree
        begin(next)
    }

    func endHere() async {
        await pause()
        let spot = run?.state(at: .now).coord
        finish(at: spot.map { Place(name: "Stopped on the way", coord: $0) })
    }

    func reset() async {
        runTask?.cancel()
        await perform { udid in
            if let e = await Phone.clear(udid) { return e }
            self.finish(at: nil)
            self.current = nil
            self.resetAt = nil
            try? FileManager.default.removeItem(atPath: self.statePath)
            return nil
        }
    }

    private func perform(_ body: (String) async -> String?) async {
        guard let udid = phone?.udid, !busy else { return }
        busy = true
        error = await body(udid)
        busy = false
    }

    // Same file the spoof CLI uses, so both agree on where the phone is.
    private func saveState(_ p: Place) {
        var s: [String: Any] = [
            "mode": "set", "place": p.name,
            "coord": String(format: "%.6f,%.6f", p.coord.latitude, p.coord.longitude),
            "at": ISO8601DateFormatter().string(from: .now),
        ]
        if let udid = phone?.udid { s["device"] = udid }
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: statePath))
        }
    }

    private func loadState() {
        guard let d = FileManager.default.contents(atPath: statePath),
              let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let text = (s["end"] ?? s["coord"]) as? String else { return }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let name = (s["place"] ?? s["to"]) as? String ?? "Last set"
        current = Place(name: name, coord: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]))
    }
}

@MainActor @Observable
final class Search: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { query.isEmpty ? (results = []) : (completer.queryFragment = query) }
    }
    var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = Array(completer.results.prefix(6))
        Task { @MainActor in self.results = self.query.isEmpty ? [] : r }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    func place(for completion: MKLocalSearchCompletion) async -> Place? {
        let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
        return item.map { Place(name: completion.title, coord: $0.location.coordinate) }
    }

    /// For Return in the search field: "lat, lon" or free text.
    func place(for text: String) async -> Place? {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let lat = parts[0], let lon = parts[1], abs(lat) <= 90, abs(lon) <= 180 {
            return Place(name: String(format: "%.5f, %.5f", lat, lon),
                         coord: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        if let first = results.first { return await place(for: first) }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = text
        let item = try? await MKLocalSearch(request: req).start().mapItems.first
        return item.map { Place(name: $0.name ?? text, coord: $0.location.coordinate) }
    }

    /// Name for a spot clicked on the map.
    static func name(of c: CLLocationCoordinate2D) async -> String {
        let fallback = String(format: "%.5f, %.5f", c.latitude, c.longitude)
        guard let req = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)),
              let item = try? await req.mapItems.first else { return fallback }
        return item.address?.shortAddress ?? item.name ?? fallback
    }
}

/// One-shot-ish location of this Mac (Wi-Fi based), refreshed occasionally.
final class Locator: NSObject, CLLocationManagerDelegate {
    var onFix: (@MainActor (CLLocationCoordinate2D) -> Void)?
    private let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        Task { @MainActor in self.onFix?(c) }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { m.startUpdatingLocation() }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
