import SwiftUI
import MapKit
import CoreLocation

// Configurações → Locais: places used by "ao chegar" / "ao sair" reminders.
// The list is saved in the account (server prevails); the iPhone only keeps
// the region alerts for pending tasks, with or without a date.
struct NativePlacesSettings: View {
    @ObservedObject var store: NativeStore
    @ObservedObject private var platform: NativePlatformStore
    @ObservedObject private var geofence = NativeGeofence.shared
    @StateObject private var location = NativeLocationManager()
    @State private var editing: NativePlace?
    @State private var working = false
    @State private var issue: String?
    @AppStorage("nativeLocalReminders") private var notificationsOn = false
    init(store: NativeStore) { self.store = store; self.platform = store.platform }
    private var places: [NativePlace] { NativePlace.list(platform.snapshot.config) }
    private var tasksByPlace: [String: Int] {
        var counts: [String: Int] = [:]
        // Only tasks that will warn: pending subtasks.
        for task in store.snapshot.items where task.isActive && !NativeLocationReminder.pendingItems(task).isEmpty { if let reminder = NativeLocationReminder(task.fields) { counts[reminder.placeID, default: 0] += 1 } }
        return counts
    }
    var body: some View {
        Form {
            Section {
                LabeledContent("Localização", value: location.always ? "Sempre" : location.status == .authorizedWhenInUse ? "Durante o uso" : location.status == .notDetermined ? "Ainda não solicitada" : "Bloqueada")
                if !location.always { Button(location.status == .notDetermined || location.status == .authorizedWhenInUse ? "Permitir localização “Sempre”" : "Abrir Ajustes do iPhone") { location.requestAlways() } }
                if location.allowed && !location.precise {
                    Label("“Localização exata” está desligada: o iPhone não detecta chegadas e saídas.", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    Button("Ligar Localização exata nos Ajustes") { openSettings() }
                }
                if !notificationsOn { Label("Ative as notificações em Configurações → Notificações para receber os avisos.", systemImage: "bell.slash").font(.footnote).foregroundStyle(.orange) }
            } header: { Text("Permissões") } footer: {
                Text("Com “Sempre”, o iOS avisa ao chegar ou sair mesmo com o SaldoLeve fechado, com ou sem data na tarefa. Com “Durante o uso” o aviso pode falhar. Sua posição não é enviada ao servidor.")
            }
            Section {
                if places.isEmpty { Text("Nenhum local salvo. Cadastre, por exemplo, Casa e Mercado.").foregroundStyle(.secondary) }
                ForEach(places) { place in
                    Button { editing = place } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(nativeBlue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(place.name).foregroundStyle(.primary)
                                Text((place.fields.text("address").isEmpty ? String(format: "%.5f, %.5f", place.latitude, place.longitude) : place.fields.text("address")) + " · raio \(Int(place.radius)) m").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if let count = tasksByPlace[place.id] { Text("\(count)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2).background(nativeBlue.opacity(0.12), in: Capsule()).foregroundStyle(nativeBlue) }
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { save(place, remove: true) } label: { Label("Excluir", systemImage: "trash") }.disabled(!platform.canWrite)
                    }
                }
                Button { editing = NativePlace.fresh() } label: { Label("Adicionar local no mapa", systemImage: "plus.circle") }
                    .disabled(!platform.canWrite || places.count >= 20)
            } header: { Text("Locais salvos") } footer: { Text("Até 20 locais. Deslize um local para a esquerda para excluí-lo. Na tarefa, toque em Local para escolher o lugar e se o aviso é ao chegar ou ao sair. Só avisa tarefas com subtarefas pendentes, todas juntas em um só aviso.") }
            Section {
                if geofence.log.isEmpty { Text("Nenhuma chegada ou saída registrada ainda.").foregroundStyle(.secondary) }
                ForEach(Array(geofence.log.prefix(15).enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
                if !geofence.log.isEmpty { Button("Limpar histórico", role: .destructive) { geofence.clearLog() } }
            } header: { Text("Detecções recentes neste iPhone") } footer: {
                Text(location.always ? "\(geofence.monitored) local(is) monitorado(s) pelo iOS agora." : "O histórico registra as detecções com a permissão “Sempre”.")
            }
            if let message = issue ?? platform.issue { Section { Text(message).font(.footnote).foregroundStyle(.orange) } }
        }
        .disabled(working)
        .navigationTitle("Locais").navigationBarTitleDisplayMode(.inline)
        .task { await platform.refresh() }
        .sheet(item: $editing) { place in NativePlaceEditor(place: place, isNew: !places.contains { $0.id == place.id }, location: location, save: { save($0, remove: false) }, remove: { save(place, remove: true) }) }
    }
    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
    private func save(_ place: NativePlace, remove: Bool) {
        working = true
        Task {
            defer { working = false }
            do { try await platform.savePlace(place, remove: remove); issue = nil }
            catch { issue = error.localizedDescription }
        }
    }
}

extension NativePlace {
    static func fresh() -> NativePlace {
        NativePlace(["id": .string(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()), "name": .string(""), "radius": .number(150)])
    }
}

struct NativePlaceEditor: View {
    @State private var place: NativePlace
    let isNew: Bool
    @ObservedObject var location: NativeLocationManager
    let save: (NativePlace) -> Void
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var waitingForLocation = false
    @State private var measuring = false
    @State private var metersPerPoint = 0.0
    @State private var describing: Task<Void, Never>?
    @State private var testResult: String?
    init(place: NativePlace, isNew: Bool, location: NativeLocationManager, save: @escaping (NativePlace) -> Void, remove: @escaping () -> Void) {
        _place = State(initialValue: place); self.isNew = isNew; self.location = location; self.save = save; self.remove = remove
    }
    private var hasCoordinate: Bool { place.fields["latitude"] != nil && place.fields["longitude"] != nil }
    private var coordinate: Binding<CLLocationCoordinate2D?> {
        Binding(get: { hasCoordinate ? CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude) : nil },
                set: { value in guard let value else { return }; place.fields["latitude"] = .number(value.latitude); place.fields["longitude"] = .number(value.longitude) })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Casa, Mercado, Trabalho…", text: Binding(get: { place.name }, set: { place.fields["name"] = .string(String($0.prefix(60))) }))
                }
                Section {
                    map.frame(height: 320).clipped().listRowInsets(EdgeInsets())
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Raio"); Spacer(); Text("\(Int(place.radius)) m").monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: Binding(get: { place.radius }, set: { place.fields["radius"] = .number(($0 / 10).rounded() * 10) }), in: 100...1000, step: 10)
                    }
                    if hasCoordinate {
                        Label(place.fields.text("address").isEmpty ? String(format: "%.5f, %.5f", place.latitude, place.longitude) : place.fields.text("address"), systemImage: "mappin.and.ellipse").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Onde fica") } footer: {
                    Text("Arraste o mapa para pôr o marcador no lugar certo ou toque no ponto desejado. O círculo azul é a área do aviso; use 150 a 200 m para casas e mercados.")
                }
                Section {
                    Button { waitingForLocation = true; location.locate() } label: { Label(location.locating && waitingForLocation ? "Obtendo localização…" : "Usar minha localização atual", systemImage: "location.fill") }.disabled(location.locating)
                    HStack {
                        TextField("Buscar endereço ou estabelecimento", text: $query).submitLabel(.search).onSubmit(search)
                        if searching { ProgressView() } else { Button("Buscar", action: search).disabled(query.trimmingCharacters(in: .whitespaces).count < 3) }
                    }
                    ForEach(results, id: \.self) { item in
                        Button { choose(item) } label: {
                            VStack(alignment: .leading, spacing: 2) { Text(item.name ?? "Local").foregroundStyle(.primary); Text(address(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    if let issue = location.issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                } header: { Text("Buscar") }
                if !isNew {
                    testSection
                    Section { Button("Excluir local", role: .destructive) { remove(); dismiss() } }
                }
            }
            .navigationTitle(isNew ? "Novo local" : place.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save(place); dismiss() }.bold().disabled(!place.valid) }
            }
            .onAppear { if isNew && !hasCoordinate && location.allowed { waitingForLocation = true; location.locate() } }
            .onChange(of: location.location) { value in
                guard waitingForLocation, let value else { return }
                waitingForLocation = false
                coordinate.wrappedValue = value.coordinate
                place.fields["address"] = .string("Localização atual (\(Int(value.horizontalAccuracy)) m de precisão)")
                describe(value.coordinate)
            }
        }
    }
    // The circle and the marker are overlays of the map, so a circle larger than
    // the map (deep zoom) is clipped instead of stretching the row.
    private var map: some View {
        NativePlaceMap(center: coordinate, radius: place.radius, showsUser: location.allowed, metersPerPoint: $metersPerPoint, moved: describe)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    if metersPerPoint > 0 {
                        let diameter = min(4000, place.radius * 2 / metersPerPoint)
                        Circle().fill(nativeBlue.opacity(0.14)).overlay(Circle().stroke(nativeBlue, lineWidth: 2)).frame(width: diameter, height: diameter)
                    }
                    Image(systemName: "mappin").font(.system(size: 36, weight: .semibold)).foregroundStyle(.red).shadow(radius: 2).offset(y: -18)
                    Circle().fill(.red).frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().allowsHitTesting(false)
            }
    }
    private var measured: (distance: Double, inside: Bool)? {
        guard measuring, let current = location.location, hasCoordinate else { return nil }
        let distance = current.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
        return (distance, distance <= place.radius)
    }
    private var testSection: some View {
        Section {
            Button { measuring = true; location.locate() } label: { Label("Onde estou agora", systemImage: "scope") }.disabled(location.locating)
            if let measured {
                Text(measured.inside ? "Você está dentro do raio: a \(Int(measured.distance)) m do marcador." : "Você está fora do raio: a \(Self.distance(measured.distance)) do marcador.")
                    .font(.footnote).foregroundStyle(measured.inside ? Color.green : Color.secondary)
            }
            Button { test("arrive") } label: { Label("Simular chegada", systemImage: "arrow.down.right.circle") }
            Button { test("leave") } label: { Label("Simular saída", systemImage: "arrow.up.left.circle") }
            if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Testar") } footer: { Text("A simulação envia em 5 segundos o mesmo aviso que o iPhone mostraria nesse local, sem você sair de casa. Bloqueie a tela para vê-lo.") }
    }
    static func distance(_ meters: Double) -> String { meters >= 1000 ? String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",") : "\(Int(meters)) m" }
    private func test(_ trigger: String) {
        testResult = "Enviando…"
        Task { let result = await NativeGeofence.shared.fire(placeID: place.id, trigger: trigger, placeName: place.name, simulated: true); testResult = result.contains("aviso:") ? "Aviso de teste em 5 segundos. " + result : result }
    }
    // The address follows the marker after the map stops moving.
    private func describe(_ point: CLLocationCoordinate2D) {
        describing?.cancel()
        describing = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let mark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: point.latitude, longitude: point.longitude)).first, !Task.isCancelled else { return }
            let text = [mark.thoroughfare, mark.subThoroughfare, mark.subLocality, mark.locality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            place.fields["address"] = .string(String((text.isEmpty ? mark.name ?? "" : text).prefix(200)))
            if place.name.isEmpty, let name = mark.areasOfInterest?.first { place.fields["name"] = .string(String(name.prefix(60))) }
        }
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return }
        searching = true
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
        if let center = coordinate.wrappedValue ?? location.location?.coordinate { request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        MKLocalSearch(request: request).start { response, _ in
            Task { @MainActor in searching = false; results = Array((response?.mapItems ?? []).prefix(8)) }
        }
    }
    private func choose(_ item: MKMapItem) {
        describing?.cancel()
        coordinate.wrappedValue = item.placemark.coordinate
        place.fields["address"] = .string(String(((item.name.map { $0 + " · " } ?? "") + address(item)).prefix(200)))
        if place.name.isEmpty, let name = item.name { place.fields["name"] = .string(String(name.prefix(60))) }
        results = []; query = ""
    }
    private func address(_ item: MKMapItem) -> String {
        let mark = item.placemark
        return [mark.thoroughfare, mark.subThoroughfare, mark.subLocality, mark.locality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// The map of the place editor: the marker stays in the middle and the map
// moves under it (drag, or tap a point to bring it to the marker). The radius
// circle is drawn on top in SwiftUI, so it follows the zoom live.
struct NativePlaceMap: UIViewRepresentable {
    @Binding var center: CLLocationCoordinate2D?
    var radius: Double
    var showsUser: Bool
    @Binding var metersPerPoint: Double
    var moved: (CLLocationCoordinate2D) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = showsUser
        map.showsCompass = true
        map.pointOfInterestFilter = .includingAll
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        for case let other as UITapGestureRecognizer in map.subviews.first?.gestureRecognizers ?? [] where other.numberOfTapsRequired == 2 { tap.require(toFail: other) }
        map.addGestureRecognizer(tap)
        let start = center ?? CLLocationManager().location?.coordinate ?? CLLocationCoordinate2D(latitude: -23.5505, longitude: -46.6333)
        context.coordinator.programmatic = center != nil
        context.coordinator.lastCenter = center
        map.setRegion(MKCoordinateRegion(center: start, latitudinalMeters: max(500, radius * 3.5), longitudinalMeters: max(500, radius * 3.5)), animated: false)
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if map.showsUserLocation != showsUser { map.showsUserLocation = showsUser }
        // Only a new point from outside the map (search, current location) moves
        // it; comparing with the live center would fight the finger mid-drag.
        if let center, coordinator.lastCenter.map({ Self.meters(center, $0) > 3 }) ?? true {
            coordinator.lastCenter = center; coordinator.programmatic = true
            map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: max(500, radius * 3.5), longitudinalMeters: max(500, radius * 3.5)), animated: true)
        }
        if coordinator.radius != radius {
            coordinator.radius = radius
            // Keep the whole circle in view while the radius changes.
            let side = Double(min(map.bounds.width, map.bounds.height))
            if metersPerPoint > 0, side > 0 {
                let share = radius * 2 / metersPerPoint / side
                if share > 0.92 || share < 0.18 { map.setRegion(MKCoordinateRegion(center: map.centerCoordinate, latitudinalMeters: radius * 3.5, longitudinalMeters: radius * 3.5), animated: true) }
            }
        }
    }
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativePlaceMap
        var programmatic = false
        var lastCenter: CLLocationCoordinate2D?
        var radius: Double
        init(_ parent: NativePlaceMap) { self.parent = parent; radius = parent.radius }
        private var byUser = false
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            programmatic = false; byUser = true
            map.setCenter(map.convert(gesture.location(in: map), toCoordinateFrom: map), animated: true)
        }
        // A finger on the map (drag or pinch) marks the change as the user's.
        func mapView(_ map: MKMapView, regionWillChangeAnimated animated: Bool) {
            if (map.subviews.first?.gestureRecognizers ?? []).contains(where: { [.began, .changed, .ended].contains($0.state) }) { programmatic = false; byUser = true }
        }
        func mapViewDidChangeVisibleRegion(_ map: MKMapView) { measure(map) }
        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            measure(map)
            let point = map.centerCoordinate, byUser = self.byUser && !programmatic
            programmatic = false; self.byUser = false; lastCenter = point
            DispatchQueue.main.async {
                let before = self.parent.center
                self.parent.center = point
                if byUser || before == nil { self.parent.moved(point) }
            }
        }
        private func measure(_ map: MKMapView) {
            guard map.bounds.width > 0 else { return }
            let y = map.bounds.midY
            let left = map.convert(CGPoint(x: 0, y: y), toCoordinateFrom: map), right = map.convert(CGPoint(x: map.bounds.width, y: y), toCoordinateFrom: map)
            let value = CLLocation(latitude: left.latitude, longitude: left.longitude).distance(from: CLLocation(latitude: right.latitude, longitude: right.longitude)) / Double(map.bounds.width)
            guard value > 0, abs(value - parent.metersPerPoint) / value > 0.003 else { return }
            DispatchQueue.main.async { self.parent.metersPerPoint = value }
        }
    }
}

// The "Local" option of a task: which saved place, and arrive or leave.
struct NativeTaskLocationSheet: View {
    @Binding var fields: JSONObject
    @ObservedObject var store: NativeStore
    @StateObject private var location = NativeLocationManager()
    @Environment(\.dismiss) private var dismiss
    @State private var managing = false
    @State private var creating: NativePlace?
    @State private var working = false
    @State private var issue: String?
    private var places: [NativePlace] { NativePlace.list(store.platform.snapshot.config) }
    private var current: NativeLocationReminder? { NativeLocationReminder(fields) }
    var body: some View {
        NavigationStack {
            Form {
                if !location.always || !location.precise {
                    Section {
                        Button(location.allowed && !location.precise ? "Ligar Localização exata nos Ajustes" : "Permitir localização “Sempre”") {
                            if location.allowed && !location.precise, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } else { location.requestAlways() }
                        }
                    } footer: { Text("Com “Sempre” e “Localização exata”, o iPhone avisa ao chegar ou sair mesmo com o app fechado, com ou sem data na tarefa.") }
                }
                Section {
                    Picker("Avisar", selection: Binding(get: { current?.trigger ?? "arrive" }, set: { set(place: current?.placeID ?? places.first?.id, trigger: $0) })) {
                        Text("Ao chegar").tag("arrive"); Text("Ao sair").tag("leave")
                    }.pickerStyle(.segmented).disabled(current == nil)
                    ForEach(places) { place in
                        Button { set(place: current?.placeID == place.id ? nil : place.id, trigger: current?.trigger ?? "arrive") } label: {
                            HStack { Label(place.name, systemImage: "mappin.circle"); Spacer(); if current?.placeID == place.id { Image(systemName: "checkmark").foregroundStyle(nativeBlue) } }
                        }.foregroundStyle(.primary)
                    }
                    Button { creating = NativePlace.fresh() } label: { Label(working ? "Salvando local…" : "Novo local no mapa", systemImage: "plus.circle") }
                        .disabled(!store.platform.canWrite || places.count >= 20 || working)
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                } header: { Text("Local") } footer: { Text("Só avisa enquanto a tarefa tiver subtarefas pendentes, como os itens de uma lista de mercado; o aviso mostra esses itens. Sem subtarefas pendentes, nada é enviado. Salve a tarefa para confirmar no servidor.") }
                Section {
                    Button { managing = true } label: { Label("Gerenciar locais", systemImage: "mappin.and.ellipse") }
                    if current != nil { Button("Remover lembrete por local", role: .destructive) { fields["locationReminder"] = .null } }
                }
            }
            .navigationTitle("Lembrete por local").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() }.bold() } }
            .sheet(isPresented: $managing) { NavigationStack { NativePlacesSettings(store: store).toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { managing = false } } } } }
            .sheet(item: $creating) { place in NativePlaceEditor(place: place, isNew: true, location: location, save: { add($0) }, remove: {}) }
        }
    }
    // The new place is saved in the account first; only then the task points to it.
    private func add(_ place: NativePlace) {
        working = true
        Task {
            defer { working = false }
            do { try await store.platform.savePlace(place); issue = nil; set(place: place.id, trigger: current?.trigger ?? "arrive") }
            catch { issue = error.localizedDescription }
        }
    }
    private func set(place: String?, trigger: String) {
        guard let place else { fields["locationReminder"] = .null; return }
        fields["locationReminder"] = .object(["placeId": .string(place), "trigger": .string(trigger)])
    }
}
