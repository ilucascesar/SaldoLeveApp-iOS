import UIKit

@MainActor enum NativeWarningPresenter {
    static func confirm(_ warnings: [JSONObject]) async -> Bool {
        guard !warnings.isEmpty else { return true }
        var lines: [String] = []
        for warning in warnings {
            let field = warning.text("field").lowercased()
            let money = field.contains("amount") || field.contains("cents")
            func display(_ value: JSONValue?) -> String {
                if money, let number = value?.number { return NativeDate.money(number) }
                return value == nil || value == .null ? "Sem referência anterior" : value?.string ?? ""
            }
            lines.append(warning.text("message") + "\nReferência: " + display(warning["before"]) + "\nInformado: " + display(warning["after"]))
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
                guard var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { continuation.resume(returning: false); return }
                while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
                if let navigation = controller as? UINavigationController { controller = navigation.visibleViewController ?? controller }
                let alert = UIAlertController(title: "Confira antes de salvar", message: lines.joined(separator: "\n\n"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Revisar", style: .cancel) { _ in continuation.resume(returning: false) })
                alert.addAction(UIAlertAction(title: "Confirmar dados informados", style: .default) { _ in continuation.resume(returning: true) })
                controller.present(alert, animated: true)
            }
        }
    }
}
