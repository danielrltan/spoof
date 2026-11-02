import MapKit
import SwiftUI

@main
struct SpoofApp: App {
    var body: some Scene {
        Window("Spoof", id: "main") {
            ContentView().frame(minWidth: 900, minHeight: 600).tint(.red)
        }
        .defaultSize(width: 1200, height: 780)
    }
}

extension Pace {
    var color: Color { switch self { case .walk: .green; case .bike: .teal; case .drive: .blue } }
}

func kmh(_ ms: Double) -> String { String(format: "%.0f", ms * 3.6) }

func clock(_ s: Double) -> String {
    let s = max(0, s)
    if s < 60 { return String(format: "%.0f s", s) }
    let m = Int((s / 60).rounded())
    return m < 60 ? "\(m) min" : String(format: "%d h %02d min", m / 60, m % 60)
}

func km(_ m: Double) -> String { m >= 1000 ? String(format: "%.1f km", m / 1000) : String(format: "%.0f m", m) }

struct ContentView: View {
    @State private var model = AppModel()
    @State private var search = Search()
    @State private var camera: MapCameraPosition = .automatic
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 310, ideal: 350, max: 440)
        } detail: {
            ZStack(alignment: .bottom) {
                TimelineView(.periodic(from: .now, by: 1)) { tl in map(now: tl.date) }
                    .ignoresSafeArea()
                    .backgroundExtensionEffect()
                TimelineView(.periodic(from: .now, by: 1)) { tl in cards(now: tl.date) }
                    .padding(20)
            }
            .toolbar { toolbar }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .searchable(text: $search.query, placement: .sidebar, prompt: "Search a place or paste lat, lon")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            let q = search.query
            Task { if let p = await search.place(for: q) { show(p); search.query = "" } }
        }
        .task { await model.watchPhone() }
        .task(id: planSignature) { await model.fetchRoutes(model.plannedLegs) }
        .onAppear {
            if let c = model.current { camera = .region(.init(center: c.coord, latitudinalMeters: 3000, longitudinalMeters: 3000)) }
        }
    }

    @ViewBuilder private func cards(now: Date) -> some View {
        VStack(spacing: 10) {
            if let setup = model.setup, model.run == nil { SetupCard(setup: setup) }
            if let run = model.run {
                RunHUD(model: model, run: run, now: now)
            } else if model.selected != nil || model.error != nil {
                placeCard
            }
        }
    }

    // MARK: sidebar

    @ViewBuilder private var sidebar: some View {
        if search.query.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { tl in TripPanel(model: model, now: tl.date) }
        } else {
            List(search.results, id: \.self) { r in
                Button {
                    Task {
                        if let p = await search.place(for: r) { show(p) }
                        search.query = ""
                        searchFocused = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title)
                        if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { phonePicker }
        if model.current != nil || model.run != nil {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { Task { await model.reset() } } label: {
                    Label("Real GPS", systemImage: "location.slash").labelStyle(.titleAndIcon)
                }
                .disabled(model.phone == nil || model.busy)
                .help("Stop faking and give the phone its real location back")
            }
            if model.run == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.pin() } } label: {
                        Label("Pin", systemImage: "mappin").labelStyle(.titleAndIcon)
                    }
                    .disabled(model.phone == nil || model.busy)
                    .help("Send the faked spot again so the phone reports standing still there")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                TimelineView(.periodic(from: .now, by: 1)) { tl in resetTimer(now: tl.date) }
            }
        }
    }

    private var planSignature: String {
        let s = model.tripStart.map { "\($0.coord.latitude),\($0.coord.longitude)" } ?? "-"
        return s + model.stops.map { "|\($0.place.coord.latitude),\($0.place.coord.longitude),\($0.pace.rawValue)" }.joined()
    }

    // MARK: map

    private func map(now: Date) -> some View {
        let legs = model.run?.legs ?? model.plannedLegs
        let first = model.run?.legs.first?.from ?? model.tripStart
        return MapReader { proxy in
            Map(position: $camera) {
                ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                    if let path = leg.path {
                        MapPolyline(coordinates: path.points).stroke(leg.pace.color.opacity(0.75), lineWidth: 5)
                    }
                }
                if let first, !legs.isEmpty || model.start != nil {
                    Marker(first.name, systemImage: "flag.fill", coordinate: first.coord).tint(.gray)
                }
                ForEach(Array(legs.enumerated()), id: \.offset) { i, leg in
                    Marker(leg.to.name, monogram: Text("\(i + 1)"), coordinate: leg.to.coord).tint(leg.pace.color)
                }
                if let s = model.selected {
                    Marker(s.name, coordinate: s.coord).tint(.orange)
                }
                if let spot = model.phoneSpot(at: now) {
                    Annotation("", coordinate: spot) { PhoneDot() }
                }
            }
            .mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
            // Left on .automatic the map jumps to frame every new marker, so a click loses your place.
            .onMapCameraChange { if camera == .automatic { camera = .region($0.region) } }
            .onTapGesture { pt in
                searchFocused = false
                guard let c = proxy.convert(pt, from: .local) else { return }
                model.selected = Place(name: String(format: "%.5f, %.5f", c.latitude, c.longitude), coord: c)
                Task {
                    let name = await Search.name(of: c)
                    if model.selected?.coord.latitude == c.latitude { model.selected?.name = name }
                }
            }
        }
    }

    private func show(_ p: Place) {
        model.selected = p
        withAnimation { camera = .region(.init(center: p.coord, latitudinalMeters: 2500, longitudinalMeters: 2500)) }
    }

    // MARK: phone + reset

    private var phonePicker: some View {
        Menu {
            ForEach(model.phones) { p in
                Button { model.choose(p) } label: {
                    Label(p.name + (p.wired ? "" : " (Wi-Fi)"),
                          systemImage: p.udid == model.chosenUDID ? "checkmark" : p.wired ? "cable.connector" : "wifi")
                }
            }
            if model.phones.isEmpty { Text("No iPhones found") }
        } label: {
            Label(phoneLabel, systemImage: model.phone == nil ? "iphone.slash" : model.phone?.wired == false ? "wifi" : "iphone")
                .labelStyle(.titleAndIcon)
        }
        .tint(nil as Color?)
        // MapKit keeps the map light in dark mode, so this capsule is always on a light surface.
        .colorScheme(.light)
        .disabled(model.run != nil)
        .help(model.run != nil ? "A trip is playing on this phone" : "Choose which iPhone to fake")
    }

    private var phoneLabel: String {
        if let p = model.phone { return p.name }
        if let name = model.setup?.pill { return name }
        if !model.checkedPhone { return "Looking for iPhone…" }
        if let n = model.chosenName { return "\(n) not found" }
        return "Plug in your iPhone"
    }

    private static let timerChoices: [(String, Double)] = [
        ("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120),
        ("4 hours", 240), ("8 hours", 480), ("12 hours", 720), ("24 hours", 1440),
    ]

    @ViewBuilder private func resetTimer(now: Date) -> some View {
        if let t = model.resetAt {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text(t > now ? Self.countdown(t.timeIntervalSince(now)) : "when plugged in")
                    .monospacedDigit()
                Button { model.resetAt = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Cancel the timer")
            }
            .help("Real GPS at \(t.formatted(date: .omitted, time: .shortened)). The phone has to be plugged in then; if it isn't, it resets the moment it is.")
        } else {
            Menu {
                Section("Back to real GPS in") {
                    ForEach(Self.timerChoices, id: \.1) { c in
                        Button(c.0) { model.resetAfter(minutes: c.1) }
                    }
                }
            } label: {
                Image(systemName: "timer")
            }
            .menuIndicator(.hidden)
            .tint(nil as Color?)
            .help("Give the phone its real location back after a while")
        }
    }

    private static func countdown(_ s: TimeInterval) -> String {
        let t = Int(s.rounded(.up))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: selected place

    private var placeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = model.selected {
                HStack(alignment: .firstTextBaseline) {
                    Text(s.name).font(.headline).lineLimit(1)
                    Spacer()
                    Button { model.selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Text(String(format: "%.5f, %.5f", s.coord.latitude, s.coord.longitude))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button { Task { await model.teleport() } } label: {
                        Label("Teleport", systemImage: "location.fill").frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.phone == nil)
                    ForEach(Pace.allCases) { pace in
                        Button { Task { await model.travel(pace) } } label: {
                            Label(pace.rawValue.capitalized, systemImage: pace.icon)
                        }
                        .buttonStyle(.bordered)
                        .tint(nil as Color?)
                        .disabled(model.phone == nil || model.phoneSpot(at: .now) == nil)
                        .help(model.phoneSpot(at: .now) == nil ? "Waiting for this Mac's location (allow Location for Spoof), or Teleport first" : "")
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.addStop(s)
                        model.selected = nil
                    } label: {
                        Label(model.tripStart == nil ? "Start trip here" : "Add stop", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(nil as Color?)
                    if model.busy { ProgressView().controlSize(.small) }
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(model.busy)
            }
            if let e = model.error {
                Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .glassCard()
    }
}

struct SetupCard: View {
    let setup: Setup

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(setup.title).font(.headline)
                Text(setup.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .glassCard()
    }
}

// MARK: trip planner

struct TripPanel: View {
    @Bindable var model: AppModel
    let now: Date

    var body: some View {
        let planRun = model.run?.planned == true ? model.run : nil
        let running = planRun != nil
        let legs = (planRun?.cableFree == false ? planRun?.legs : nil) ?? model.plannedLegs
        let activeLeg = planRun?.cableFree == false ? planRun?.state(at: now).leg : nil
        let empty = model.run == nil && model.stops.isEmpty && model.start == nil
        List {
            if !empty {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "flag.fill").foregroundStyle(.secondary).frame(width: 22)
                        Text(planRun?.legs.first?.from.name ?? model.tripStart?.name ?? "Pick a start").lineLimit(1)
                        Spacer()
                        if !running {
                            Menu {
                                if model.current != nil { Button("Phone's spot") { model.start = nil } }
                                if let s = model.selected { Button("Selected: \(s.name)") { model.start = s } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    ForEach(Array(model.stops.enumerated()), id: \.element.id) { i, stop in
                        let leg = i < legs.count ? legs[i] : nil
                        StopRow(model: model, id: stop.id, leg: leg, last: i == model.stops.count - 1,
                                active: activeLeg == i, done: (activeLeg ?? -1) > i, running: running)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { model.stops.move(fromOffsets: $0, toOffset: $1) }
                    .moveDisabled(running)
                } header: {
                    HStack {
                        Text("Trip")
                        Spacer()
                        if !running {
                            Button("Clear") { model.stops = []; model.start = nil }
                                .buttonStyle(.plain).padding(.trailing, 10)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if empty { ContentUnavailableView("Click the map to pick a place", systemImage: "map") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !model.stops.isEmpty {
                    footer(legs, running: running)
                    Divider().padding(.horizontal, 14)
                }
                Toggle("Cable-free trips", isOn: $model.cableFree)
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(model.run != nil)
                    .help("Each trip plays as one route at a steady speed, so you can unplug once it starts. No speed-limit changes or stays.")
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func footer(_ legs: [Leg], running: Bool) -> some View {
        let ready = legs.count == model.stops.count && legs.allSatisfy { !$0.pieces.isEmpty }
        let moving = legs.reduce(0) { $0 + $1.duration }, length = legs.reduce(0) { $0 + $1.length }
        let total = moving + (model.cableFree ? 0 : model.stops.dropLast().reduce(0) { $0 + $1.stayMinutes * 60 })
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if ready {
                    Text("\(km(length)) · \(clock(total))" + (model.cableFree && moving > 0 ? " · steady \(kmh(length / moving)) km/h" : ""))
                    if !running {
                        Text("arrive \(Date.now.addingTimeInterval(total).formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if legs.contains(where: \.failed) {
                    Text("No route for a leg").foregroundStyle(.red)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Finding roads…").foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if !running {
                Button { Task { await model.startTrip() } } label: { Label("Start trip", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .disabled(!ready || model.phone == nil)
            }
        }
        .padding(14)
    }
}

struct StopRow: View {
    @Bindable var model: AppModel
    let id: UUID
    let leg: Leg?
    let last: Bool
    let active: Bool
    let done: Bool
    let running: Bool

    var body: some View {
        // Look the stop up by id: after a delete SwiftUI may redraw a row whose old position is gone.
        if let index = model.stops.firstIndex(where: { $0.id == id }) {
            row(index, model.stops[index])
        }
    }

    private func row(_ index: Int, _ stop: Stop) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The leg that arrives at this stop.
            HStack(spacing: 8) {
                Rectangle().fill(stop.pace.color.opacity(done ? 0.3 : 0.8)).frame(width: 3).padding(.leading, 9).padding(.trailing, 10)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Picker("", selection: field(\.pace, .drive)) {
                            ForEach(Pace.allCases) { Image(systemName: $0.icon).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        TextField(leg.map { clock($0.pieces.isEmpty ? 0 : Self.natural($0)) } ?? "min",
                                  text: minutes(field(\.minutes, nil)))
                            .textFieldStyle(.roundedBorder).frame(width: 64)
                            .help("Leg duration in minutes; leave empty for the normal pace")
                        Text("min").foregroundStyle(.secondary).font(.caption)
                    }
                    if let leg, !leg.pieces.isEmpty {
                        HStack(spacing: 6) {
                            Text("\(km(leg.length)) · \(clock(leg.duration)) · avg \(kmh(leg.average))")
                            if leg.pace == .drive { Text("· top \(kmh(leg.top)) km/h") } else { Text("km/h") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let o = leg.over {
                            Text("up to \(kmh(o.speed)) in a \(kmh(o.limit)) zone").font(.caption).foregroundStyle(.orange)
                        }
                    } else if leg?.failed == true {
                        Text("No route").font(.caption).foregroundStyle(.red)
                    }
                }
                .disabled(running)
            }
            HStack(spacing: 8) {
                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Circle().fill(stop.pace.color))
                Text(stop.place.name).fontWeight(active ? .semibold : .regular).lineLimit(1)
                Spacer()
                if !last, !model.cableFree {
                    TextField("0", text: stay(field(\.stayMinutes, 0)))
                        .textFieldStyle(.roundedBorder).frame(width: 44).disabled(running)
                        .help("Minutes to stay here before the next leg")
                    Text("min stay").font(.caption).foregroundStyle(.secondary)
                }
                if !running {
                    Button { model.stops.removeAll { $0.id == id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(done ? 0.55 : 1)
    }

    /// A binding to one field of this stop that tolerates the stop having been deleted.
    private func field<T>(_ kp: WritableKeyPath<Stop, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { model.stops.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in if let i = model.stops.firstIndex(where: { $0.id == id }) { model.stops[i][keyPath: kp] = v } })
    }

    /// Duration of the leg at its normal pace, for the placeholder.
    private static func natural(_ leg: Leg) -> Double {
        guard let path = leg.path else { return leg.duration }
        return Profile.pieces(path, pace: leg.pace).reduce(0) { $0 + $1.duration }
    }

    private func minutes(_ b: Binding<Double?>) -> Binding<String> {
        Binding(get: { b.wrappedValue.map { String(format: "%g", $0) } ?? "" },
                set: { b.wrappedValue = Double($0.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil } })
    }

    private func stay(_ b: Binding<Double>) -> Binding<String> {
        Binding(get: { b.wrappedValue > 0 ? String(format: "%g", b.wrappedValue) : "" },
                set: { b.wrappedValue = max(0, Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0) })
    }
}

// MARK: live trip

struct RunHUD: View {
    let model: AppModel
    let run: Run
    let now: Date

    var body: some View {
        let st = run.state(at: now)
        let leg = run.legs[min(st.leg, run.legs.count - 1)]
        let elapsed = run.paused ? 0 : max(0, now.timeIntervalSince(run.base))
        let left = max(0, run.total - elapsed)
        let parked: Bool = {
            if run.paused { return true }
            if case .park = run.steps[run.index(at: now)] { return true }
            return false
        }()
        HStack(spacing: 18) {
            VStack(spacing: 0) {
                Text(kmh(st.speed)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("km/h").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 70)
            if let limit = st.limit {
                Text(kmh(limit)).font(.system(size: 17, weight: .bold, design: .rounded))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(.red, lineWidth: 5))
                    .foregroundStyle(.black)
                    .help("Posted limit")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: run.paused ? "pause.fill" : parked ? "mappin" : leg.pace.icon)
                    Text(run.paused ? "Paused" : parked ? "At \(leg.to.name)" : "\(leg.pace.verb) to \(leg.to.name)")
                        .font(.headline).lineLimit(1)
                    Spacer()
                    Text(run.paused ? "\(clock(left)) left" : "arrive \(now.addingTimeInterval(left).formatted(date: .omitted, time: .shortened)) · \(clock(left))")
                        .foregroundStyle(.secondary)
                }
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
                if run.arrivedUnparked {
                    Text("Arrived, but the phone isn't answering, so it still looks like it's moving. It gets pinned here the moment it answers; plugging it in helps.")
                        .font(.caption).foregroundStyle(.orange)
                } else if run.cableFree, model.phone == nil {
                    Text("Playing on the phone. Plug in to pause or end early.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if run.paused {
                        Button { model.resume() } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(model.phone == nil)
                    } else {
                        Button { Task { await model.pause() } } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .disabled(model.phone == nil || run.arrivedUnparked)
                    }
                    Button("End here") { Task { await model.endHere() } }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(model.phone == nil || run.arrivedUnparked)
                    Spacer()
                    Text("Leg \(st.leg + 1) of \(run.legs.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .glassCard()
    }
}

struct PhoneDot: View {
    var body: some View {
        ZStack {
            Circle().fill(.blue.opacity(0.18)).frame(width: 34, height: 34)
            Circle().fill(.white).frame(width: 18, height: 18)
            Circle().fill(.blue).frame(width: 13, height: 13)
        }
        .shadow(radius: 2)
    }
}

extension View {
    /// The floating surface every card over the map shares. Controls inside stay standard:
    /// Liquid Glass doesn't stack on itself.
    func glassCard() -> some View {
        padding(18)
            .frame(maxWidth: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}
