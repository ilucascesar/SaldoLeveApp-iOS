import Foundation
import Contacts
import CryptoKit

struct NativeContactBirthdays {
    var items: [NativeBirthday]
    var skipped: Int
    var limited: Bool
}

enum NativeBirthdayContacts {
    // Automatic sync never asks for permission; it only runs after the user
    // allowed Contacts (fully or for selected contacts).
    static var authorized: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        if #available(iOS 18.0, *) { return status == .limited }
        return false
    }
    static func load(prompt: Bool = true) async throws -> NativeContactBirthdays {
        if !prompt && !authorized { throw NativeFailure("Contatos sem permissão.") }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-contacts") {
            let item = NativeBirthday(["sourceKey": .string("fixture-contact"), "name": .string("Contato de teste"), "month": .number(2), "day": .number(29), "year": .null, "group": .string("Amigos"), "daysBefore": .array([.number(0)]), "time": .string("09:00"), "enabled": .bool(true), "timezone": .string("America/Sao_Paulo"), "leapPolicy": .string("feb28")])
            return .init(items: [item], skipped: 1, limited: true)
        }
        #endif
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                CNContactStore().requestAccess(for: .contacts) { granted, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                }
            }
            guard granted else { throw NativeFailure("O acesso aos Contatos não foi permitido. Você pode liberar nos Ajustes do iPhone ou cadastrar aniversários manualmente.") }
        } else if status == .denied || status == .restricted {
            throw NativeFailure("Permita acesso aos Contatos nos Ajustes do iPhone para escolher aniversários. O cadastro manual continua disponível.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactBirthdayKey, CNContactNonGregorianBirthdayKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys); request.unifyResults = true
            var items: [NativeBirthday] = [], skipped = 0
            let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
            try store.enumerateContacts(with: request) { contact, _ in
                guard let birthday = contact.birthday, let month = birthday.month, let day = birthday.day, (1...12).contains(month), (1...31).contains(day) else { skipped += 1; return }
                let name = ([contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
                let display = name.isEmpty ? (contact.nickname.isEmpty ? contact.organizationName : contact.nickname) : name
                guard !display.isEmpty else { skipped += 1; return }
                var value = NativeBirthday.fresh()
                let source = SHA256.hash(data: Data(contact.identifier.utf8)).map { String(format: "%02x", $0) }.joined()
                value.fields["name"] = .string(display); value.fields["month"] = .number(Double(month)); value.fields["day"] = .number(Double(day)); value.fields["sourceKey"] = .string(source)
                if let year = birthday.year, (1...currentYear).contains(year) { value.fields["year"] = .number(Double(year)) }
                items.append(value)
            }
            var limited = false
            if #available(iOS 18.0, *) { limited = CNContactStore.authorizationStatus(for: .contacts) == .limited }
            return NativeContactBirthdays(items: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, skipped: skipped, limited: limited)
        }.value
    }
}
