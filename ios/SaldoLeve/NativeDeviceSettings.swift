import SwiftUI

struct NativeDeviceSettings: View {
    @ObservedObject var store: NativeStore
    @State private var devices: [JSONObject] = []
    @State private var removing: NativeRecord?
    @State private var issue: String?
    var body: some View {
        List {
            Section { Text("Seu acesso fica salvo no armazenamento seguro do iPhone. A senha não é guardada. O acesso é renovado durante o uso e expira após 180 dias sem renovação, ao trocar a senha, sair ou revogar o aparelho.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(devices.map(NativeRecord.init)) { record in
                VStack(alignment: .leading, spacing: 7) { Text(record.fields.text("name") + (record.fields.flag("current") ? " · Este iPhone" : "")).font(.headline); Text(record.fields.flag("active") ? "Acesso ativo" : "Revogado ou expirado").font(.caption).foregroundStyle(.secondary); if record.fields.flag("active") { Button("Revogar acesso", role: .destructive) { removing = record } } }
            }
            if let issue { Text(issue).foregroundStyle(.red) }
        }.navigationTitle("Aparelhos conectados").navigationBarTitleDisplayMode(.inline).task { await reload() }
            .confirmationDialog("Revogar o acesso deste aparelho?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) { Button("Revogar acesso", role: .destructive) { if let removing { Task { do { if try await store.api.revokeDevice(removing.id) { store.reminders.clear(); store.finance.reset(); store.user = nil; NativeCache.remove(store.api.storageID) } else { await reload() } } catch { issue = error.localizedDescription } } }; removing = nil } }
    }
    private func reload() async { do { devices = try await store.api.devices().objects("devices"); issue = nil } catch { issue = error.localizedDescription } }
}
