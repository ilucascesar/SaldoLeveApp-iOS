import SwiftUI

struct NativeTaskConflictReview: View {
    let task: NativeTask
    let conflicts: [NativeTaskConflict]
    let apply: (NativeTask) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Escolha o conteúdo de cada campo que mudou nos dois lugares. As outras alterações serão combinadas automaticamente.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(conflicts) { conflict in
                    Section(conflict.label) {
                        choice("Neste iPhone", value: conflict.localValue(in: task), conflict: conflict, remote: false)
                        choice("Na sua conta", value: conflict.remote, conflict: conflict, remote: true)
                    }
                }
            }.navigationTitle("Revisar alterações").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Depois") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Aplicar") {
                            var resolved = task
                            for conflict in conflicts where choices[conflict.id] == true { resolved = conflict.takingRemote(in: resolved) }
                            apply(resolved); dismiss()
                        }.disabled(conflicts.contains { choices[$0.id] == nil })
                    }
                }
        }
    }
    private func choice(_ title: String, value: JSONValue?, conflict: NativeTaskConflict, remote: Bool) -> some View {
        Button { choices[conflict.id] = remote } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.bold())
                    Text(conflict.key?.hasSuffix("Cents") == true && value?.number != nil ? NativeDate.money(value?.number) : NativeTaskConflict.display(value)).font(.body).foregroundStyle(.primary).lineLimit(8)
                }
                Spacer()
                Image(systemName: choices[conflict.id] == remote ? "checkmark.circle.fill" : "circle").padding(.top, 2)
            }.padding(.vertical, 4)
        }.buttonStyle(.plain).accessibilityLabel(title + ": " + NativeTaskConflict.display(value)).accessibilityIdentifier("task-conflict-" + (remote ? "account-" : "local-") + conflict.id)
    }
}
