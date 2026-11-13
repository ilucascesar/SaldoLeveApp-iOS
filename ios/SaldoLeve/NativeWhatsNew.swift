import SwiftUI

@MainActor
struct NativeWhatsNewView: View {
    @ObservedObject var store: NativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var notes: JSONObject = [:]
    @State private var dontShow = false
    @State private var busy = false
    @State private var loaded = false
    @State private var issue: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(nativeBlue).accessibilityHidden(true)
                    Text("Novidades").font(.largeTitle.bold())
                    Text("SaldoLeve · versão " + NativeRelease.version).foregroundStyle(.secondary)
                }
                if !loaded && issue == nil { ProgressView("Carregando novidades…") }
                ForEach(Array(notes.objects("changes").enumerated()), id: \.offset) { _, change in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: change.text("icon")).font(.title3).foregroundStyle(nativeBlue).frame(width: 28).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(change.text("title")).font(.headline)
                            Text(change.text("text")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if loaded && !notes.flag("available") { Text("As novidades desta versão não estão disponíveis no servidor.").foregroundStyle(.secondary) }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.red); Button("Tentar novamente") { Task { await load() } } }
                if notes.flag("available") {
                    Toggle("Não mostrar novamente nesta versão", isOn: $dontShow).disabled(busy)
                    Text("Você pode rever esta tela em Configurações → Novidades da versão.").font(.footnote).foregroundStyle(.secondary)
                }
                Button(busy ? "Salvando…" : "Continuar") { Task { await finish() } }
                    .buttonStyle(.borderedProminent).disabled(busy).frame(maxWidth: .infinity)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.navigationTitle("Novidades").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: dontShow) { value in
            if loaded && notes.flag("available") && value != notes.flag("dismissed") { Task { await saveChoice() } }
        }
        .navigationBarBackButtonHidden(busy || dontShow != notes.flag("dismissed"))
        .interactiveDismissDisabled(busy || dontShow != notes.flag("dismissed"))
    }
    private func load() async {
        issue = nil
        do {
            notes = try await store.api.get(JSONObject.self, action: "release_notes", query: ["platform":"ios", "version":NativeRelease.version])
            dontShow = notes.flag("dismissed"); loaded = true
        } catch { issue = error.localizedDescription }
    }
    private func finish() async {
        guard !busy else { return }
        if notes.flag("available") && dontShow != notes.flag("dismissed") { await saveChoice() }
        if dontShow == notes.flag("dismissed") { dismiss() }
    }
    private func saveChoice() async {
        guard !busy else { return }
        busy = true; issue = nil
        defer { busy = false }
        do {
            let result = try await store.api.post(action: "release_seen", body: ["platform":.string("ios"), "version":.string(NativeRelease.version), "dismissed":.bool(dontShow)])
            notes["dismissed"] = .bool(result.flag("dismissed"))
        } catch { dontShow = notes.flag("dismissed"); issue = error.localizedDescription }
    }
}

enum NativeRelease {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
}
