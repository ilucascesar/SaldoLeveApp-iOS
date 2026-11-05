import SwiftUI

struct NativePaidStamp: View {
    var compact = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Label("PAGO", systemImage: "checkmark.seal.fill")
            .font(.system(size: compact ? 8 : 11, weight: .heavy))
            .foregroundStyle(scheme == .dark ? Color(nativeHex: "#A8EBC8") : Color(nativeHex: "#137145")).padding(.horizontal, compact ? 4 : 7).padding(.vertical, 4)
            .background(Color.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.green.opacity(0.55), lineWidth: 1.3) }
            .accessibilityLabel("Despesa 100% paga por todos")
    }
}

struct NativeExpensePaymentStatus: View {
    let status: NativeExpenseCardPayment
    var compact = false
    var body: some View {
        if status.total > 0 && !status.participants.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                Text("\(status.settledCount)/\(status.peopleCount) pagaram").font(.system(size: compact ? 9 : 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.13))
                        Capsule().fill(Color.green.opacity(0.8)).frame(width: max(0, geometry.size.width * status.fraction))
                    }
                }.frame(height: compact ? 3 : 5).accessibilityLabel("Pagamento: \(Int(status.fraction * 100)) por cento")
                ForEach(Array(status.participants.prefix(compact ? 3 : 6))) { person in
                    HStack(spacing: compact ? 3 : 7) {
                        Image(systemName: person.paid ? "checkmark.circle.fill" : person.partial ? "circle.lefthalf.filled" : "clock")
                            .foregroundStyle(person.paid ? Color.green : person.partial ? .orange : .secondary)
                        Text(compact ? person.shortName : person.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(person.label).font(.system(size: compact ? 8 : 10, weight: .medium)).foregroundStyle(person.paid ? Color.green : person.partial ? .orange : .secondary).lineLimit(1).minimumScaleFactor(0.6)
                    }.font(.system(size: compact ? 9 : 12))
                        .accessibilityElement(children: .ignore).accessibilityLabel(person.name + ": " + person.label + ". Pago " + NativeDate.money(Double(person.fields.integer("paidCents"))) + ". Falta " + NativeDate.money(Double(person.fields.integer("pendingCents"))))
                }
                if status.participants.count > (compact ? 3 : 6) { Text("+\(status.participants.count - (compact ? 3 : 6)) pessoas").font(.system(size: compact ? 8 : 10)).foregroundStyle(.secondary) }
                if !status.complete { Text("Falta " + NativeDate.money(Double(status.pending))).font(.system(size: compact ? 9 : 11, weight: .semibold)).foregroundStyle(.orange).lineLimit(1).minimumScaleFactor(0.65) }
            }.accessibilityIdentifier("shared-expense-payment-status")
        }
    }
}
