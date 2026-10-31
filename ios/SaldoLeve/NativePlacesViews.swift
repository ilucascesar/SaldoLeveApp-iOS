import SwiftUI
import MapKit
import CoreLocation

// Configurações → Locais: places used by "ao chegar" / "ao sair" reminders.
// The list is saved in the account (server prevails); the iPhone only keeps
// the region alerts for pending tasks.
struct NativePlacesSettings: View {
    @ObservedObject var store: NativeStore
    @ObservedObject private var platform: NativePlatformStore
    @StateObject private var location = NativeLocationManager()
    @State private var editing: NativePlace?
    @State private var working = false
    @State private var issue: String?
    init(store: NativeStore) { self.store = store; self.platform = store.platform }
    private var places: [NativePlace] { NativePlace.list(platform.snapshot.config) }
    private var tasksByPlace: [String: Int] {
        var counts: [String: Int] = [:]
        for task in store.snapshot.items where task.isActive { if let reminder = NativeLocationReminder(task.fields) { counts[reminder.placeID, default: 0] += 1 } }
        return counts
    }
    var body: some View {
        Form {
            Section {
                LabeledContent("Localização", value: location.allowed ? "Permitida" : location.status == .notDetermined ? "Ainda não solicitada" : "Bloqueada")
                if location.status == .notDetermined { Button("Permitir localização Durante o uso") { location.request() } }
                else if !location.allowed { Button("Abrir Ajustes do iPhone") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
            } footer: { Text("“Durante o uso” basta: o iOS avisa ao chegar ou sair mesmo com o SaldoLeve fechado. A precisão é de 100 a 200 metros e sua posição não é enviada ao servidor.") }
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
                        }
                    }.buttonStyle(.plain)
                }
                Button { editing = NativePlace(["id": .string(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()), "name": .string(""), "radius": .number(150)]) } label: { Label("Adicionar local", systemImage: "plus.circle") }
                    .disabled(!platform.canWrite || places.count >= 20)
            } header: { Text("Locais salvos") } footer: { Text("Até 20 locais. Na tarefa, toque em Local para escolher o lugar e se o aviso é ao chegar ou ao sair. Tarefas do mesmo local chegam juntas em um só aviso.") }
            if let message = issue ?? platform.issue { Section { Text(message).font(.footnote).foregroundStyle(.orange) } }
        }
        .disabled(working)
        .navigationTitle("Locais").navigationBarTitleDisplayMode(.inline)
        .task { await platform.refresh() }
        .sheet(item: $editing) { place in NativePlaceEditor(place: place, isNew: !places.contains { $0.id == place.id }, location: location, save: { save($0, remove: false) }, remove: { save(place, remove: true) }) }
    }
    private func save(_ place: NativePlace, remove: Bool) {
        var list = places.filter { $0.id != place.id }.map { JSONValue.object($0.fields) }
        if !remove { list.append(.object(place.fields)) }
        working = true
        Task {
            defer { working = false }
            do { try await platform.savePlaces(list); issue = nil; store.reminders.update(store.snapshot, places: NativePlace.list(platform.snapshot.config)) }
            catch { issue = error.localizedDescription }
        }
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
    init(place: NativePlace, isNew: Bool, location: NativeLocationManager, save: @escaping (NativePlace) -> Void, remove: @escaping () -> Void) {
        _place = State(initialValue: place); self.isNew = isNew; self.location = location; self.save = save; self.remove = remove
    }
    private var hasCoordinate: Bool { place.fields["latitude"] != nil && place.fields["longitude"] != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Casa, Mercado, Trabalho…", text: Binding(get: { place.name }, set: { place.fields["name"] = .string(String($0.prefix(60))) }))
                }
                Section {
                    Button { waitingForLocation = true; location.locate() } label: { Label(location.locating ? "Obtendo localização…" : "Usar minha localização atual", systemImage: "location.fill") }.disabled(location.locating)
                    HStack {
                        TextField("Buscar endereço ou estabelecimento", text: $query).submitLabel(.search).onSubmit(search)
                        if searching { ProgressView() } else { Button("Buscar", action: search).disabled(query.trimmingCharacters(in: .whitespaces).count < 3) }
                    }
                    ForEach(results, id: \.self) { item in
                        Button { choose(item) } label: {
                            VStack(alignment: .leading, spacing: 2) { Text(item.name ?? "Local").foregroundStyle(.primary); Text(address(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    if hasCoordinate {
                        Label(place.fields.text("address").isEmpty ? String(format: "%.5f, %.5f", place.latitude, place.longitude) : place.fields.text("address"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
                    }
                    if let issue = location.issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                } header: { Text("Onde fica") }
                Section {
                    Picker("Raio", selection: Binding(get: { place.radius }, set: { place.fields["radius"] = .number($0) })) { ForEach(NativePlace.radii, id: \.self) { Text("\(Int($0)) m").tag($0) } }
                } footer: { Text("Use 150 a 200 m para casas e mercados. Raios menores podem atrasar o aviso.") }
                if !isNew { Section { Button("Excluir local", role: .destructive) { remove(); dismiss() } } }
            }
            .navigationTitle(isNew ? "Novo local" : place.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save(place); dismiss() }.bold().disabled(!place.valid) }
            }
            .onChange(of: location.location) { value in
                guard waitingForLocation, let value else { return }
                waitingForLocation = false
                place.fields["latitude"] = .number(value.coordinate.latitude); place.fields["longitude"] = .number(value.coordinate.longitude)
                place.fields["address"] = .string("Localização atual (\(Int(value.horizontalAccuracy)) m de precisão)")
            }
        }
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return }
        searching = true
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
        if let current = location.location { request.region = MKCoordinateRegion(center: current.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        MKLocalSearch(request: request).start { response, _ in
            Task { @MainActor in searching = false; results = Array((response?.mapItems ?? []).prefix(8)) }
        }
    }
    private func choose(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        place.fields["latitude"] = .number(coordinate.latitude); place.fields["longitude"] = .number(coordinate.longitude)
        place.fields["address"] = .string(String(((item.name.map { $0 + " · " } ?? "") + address(item)).prefix(200)))
        if place.name.isEmpty, let name = item.name { place.fields["name"] = .string(String(name.prefix(60))) }
        results = []; query = ""
    }
    private func address(_ item: MKMapItem) -> String {
        let mark = item.placemark
        return [mark.thoroughfare, mark.subThoroughfare, mark.subLocality, mark.locality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// The "Local" option of a task: which saved place, and arrive or leave.
struct NativeTaskLocationSheet: View {
    @Binding var fields: JSONObject
    @ObservedObject var store: NativeStore
    @StateObject private var location = NativeLocationManager()
    @Environment(\.dismiss) private var dismiss
    @State private var managing = false
    private var places: [NativePlace] { NativePlace.list(store.platform.snapshot.config) }
    private var current: NativeLocationReminder? { NativeLocationReminder(fields) }
    var body: some View {
        NavigationStack {
            Form {
                if !location.allowed {
                    Section {
                        Button("Permitir localização Durante o uso") { if location.status == .notDetermined { location.request() } else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    } footer: { Text("Sem essa permissão, o iPhone não consegue avisar ao chegar ou sair.") }
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
                    if places.isEmpty { Text("Cadastre um local primeiro, como Casa ou Mercado.").foregroundStyle(.secondary) }
                } header: { Text("Local") } footer: { Text("O aviso se repete a cada chegada ou saída enquanto a tarefa estiver pendente. Salve a tarefa para confirmar no servidor.") }
                Section {
                    Button { managing = true } label: { Label("Gerenciar locais", systemImage: "mappin.and.ellipse") }
                    if current != nil { Button("Remover lembrete por local", role: .destructive) { fields["locationReminder"] = .null } }
                }
            }
            .navigationTitle("Lembrete por local").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() }.bold() } }
            .sheet(isPresented: $managing) { NavigationStack { NativePlacesSettings(store: store).toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { managing = false } } } } }
        }
    }
    private func set(place: String?, trigger: String) {
        guard let place else { fields["locationReminder"] = .null; return }
        fields["locationReminder"] = .object(["placeId": .string(place), "trigger": .string(trigger)])
    }
}
