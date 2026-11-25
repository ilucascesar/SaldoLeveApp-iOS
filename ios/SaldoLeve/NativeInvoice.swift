import SwiftUI
import WebKit
import UniformTypeIdentifiers

// Faturas de cartão no app: "Lançar fatura" (ler o PDF no aparelho e registrar só o estudo)
// e o Panorama. O leitor e o Panorama são as páginas do próprio site (invoice-reader.html e
// invoice-panorama.html), abertas num WKWebView: o PDF é lido no aparelho e nada é gravado
// além do estudo da fatura. O valor da despesa nunca é alterado.

enum NativeInvoiceLimits {
    static let maxBytes = 15 * 1_048_576
}

struct NativeInvoiceCard: Identifiable, Hashable {
    let id: String
    let name: String
}

struct NativeInvoiceMonth: Identifiable, Hashable {
    let month: String
    let value: Double
    let analyzed: Bool
    var id: String { month }
}

enum NativeInvoiceText {
    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "BRL").locale(Locale(identifier: "pt_BR")))
    }
    static func month(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let number = Int(parts[1]), (1...12).contains(number) else { return raw }
        let names = ["Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"]
        return names[number - 1] + " de " + String(year)
    }
    /// Mês de referência = mês anterior ao vencimento (a fatura que vence em setembro é a de agosto).
    static func monthBefore(dueDate: String) -> String {
        let parts = dueDate.prefix(7).split(separator: "-")
        guard parts.count == 2, var year = Int(parts[0]), var number = Int(parts[1]) else { return "" }
        number -= 1
        if number < 1 { number = 12; year -= 1 }
        return String(format: "%04d-%02d", year, number)
    }
}

/// Mesma conferência do site (invxSums).
struct NativeInvoiceSums {
    var purchases = 0.0
    var fees = 0.0
    var interest = 0.0
    var credits = 0.0
    var payments = 0.0
    var previous = 0.0
    var paid = 0.0
    var carried = 0.0
    var charges = 0.0
    var computed = 0.0

    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    init(_ statement: JSONObject) {
        var buy = 0.0, fee = 0.0, tax = 0.0, credit = 0.0, pay = 0.0
        for line in statement.objects("transactions") {
            let amount = line.decimal("amount")
            switch line.text("kind") {
            case "fee": fee += amount
            case "interest": tax += amount
            case "refund": credit += amount
            case "payment": pay += amount
            default: buy += amount
            }
        }
        var informedPaid = false
        if let raw = statement["paymentsTotal"] {
            if case .null = raw { informedPaid = false } else { informedPaid = raw.number != nil || !raw.string.isEmpty }
        }
        previous = statement.decimal("previousBalance")
        paid = informedPaid ? -abs(statement.decimal("paymentsTotal")) : Self.round2(pay)
        carried = previous != 0 ? Self.round2(previous + paid) : 0
        charges = Self.round2(buy + fee + tax + credit)
        computed = Self.round2(carried + charges)
        purchases = Self.round2(buy)
        fees = Self.round2(fee)
        interest = Self.round2(tax)
        credits = Self.round2(credit)
        payments = Self.round2(pay)
    }
}

// MARK: - Leitor (página do site num WKWebView)

@MainActor
final class NativeInvoiceReader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let pageURL: URL
    private let address: SiteAddress
    private var pending: CheckedContinuation<Void, Error>?
    private var loaded = false

    init(address: SiteAddress) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        self.pageURL = address.home.deletingLastPathComponent().appendingPathComponent("invoice-reader.html")
        self.address = address
        super.init()
        webView.navigationDelegate = self
    }

    private func prepare() async throws {
        if loaded { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending = continuation
            webView.load(URLRequest(url: pageURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        loaded = true
    }

    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Devolve {status: ok|password|wrongPassword|error, text, statement, message}.
    func read(_ pdf: Data, password: String?, fileName: String) async throws -> JSONObject {
        guard pdf.count <= NativeInvoiceLimits.maxBytes else { throw NativeFailure("O PDF passa de 15 MB. Baixe de novo a fatura no app do banco.") }
        try await prepare()
        let ready = try await call("return await window.slReaderReady;", [:])
        guard (ready as? Bool) == true else { throw NativeFailure("O leitor de faturas não carregou. Confira a conexão e atualize o servidor.") }
        let value = try await call("return await window.slReadInvoice(base64, password, name);",
                                   ["base64": pdf.base64EncodedString(), "password": password ?? "", "name": fileName])
        guard let text = value as? String, let result = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)) else {
            throw NativeFailure("O leitor de faturas não respondeu. Tente de novo.")
        }
        return result
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pending?.resume()
        pending = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pending?.resume(throwing: error)
        pending = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pending?.resume(throwing: NativeFailure("Não foi possível abrir o leitor de faturas. Confira a conexão."))
        pending = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(address.contains(url) || url.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

// MARK: - Lançar fatura

/// Conteúdo (seções) do fluxo; deve ficar dentro de um Form.
@MainActor
struct NativeInvoiceFlow: View {
    let api: NativeAPI
    var fileData: Data?
    var fileName = ""
    var preselectedCard = ""
    let onFinish: () -> Void

    @State private var cards: [NativeInvoiceCard] = []
    @State private var cardID = ""
    @State private var data: Data?
    @State private var name = ""
    @State private var picking = false
    @State private var reader: NativeInvoiceReader?
    @State private var password = ""
    @State private var needsPassword = false
    @State private var wrongPassword = false
    @State private var savePassword = false
    @State private var triedSaved = false
    @State private var statement: JSONObject?
    @State private var note = ""
    @State private var months: [NativeInvoiceMonth] = []
    @State private var month = ""
    @State private var replace = false
    @State private var working = false
    @State private var message: String?
    @State private var issue: String?
    @State private var started = false

    private var total: Double { statement?.decimal("total") ?? 0 }
    private func matches(_ item: NativeInvoiceMonth) -> Bool { abs(item.value - total) < 0.05 }
    private var selected: NativeInvoiceMonth? { months.first { $0.month == month } }
    private var canSave: Bool { statement != nil && !working && (selected.map(matches) ?? false) }

    var body: some View {
        Group {
            if let message {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Concluir") { onFinish() }
                }
            } else {
                fileSection
                if let statement { review(statement) }
                else {
                    cardSection
                    if needsPassword { passwordSection } else { readButton }
                }
            }
            if working { Section { ProgressView("Aguarde…") } }
            if let issue { Section { Text(issue).foregroundStyle(.red) } }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType.pdf]) { result in handlePicked(result) }
        .task { await start() }
    }

    private var fileSection: some View {
        Section("Fatura em PDF") {
            if let data {
                Label(name.isEmpty ? "fatura.pdf" : name, systemImage: "doc.richtext").lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Escolha o PDF da fatura. Ele é lido neste aparelho e não é guardado.").font(.footnote).foregroundStyle(.secondary)
            }
            if fileData == nil && statement == nil {
                Button(data == nil ? "Escolher PDF" : "Escolher outro PDF") { picking = true }
            }
        }
    }

    private var cardSection: some View {
        Section("Cartão") {
            if cards.isEmpty { Text(working ? "Buscando cartões…" : "Nenhum cartão encontrado.").foregroundStyle(.secondary) }
            else {
                Picker("Cartão", selection: $cardID) {
                    ForEach(cards) { card in Text(card.name).tag(card.id) }
                }
            }
        }
    }

    private var readButton: some View {
        Section {
            Button("Ler fatura") { openInvoice(nil) }.disabled(data == nil || cardID.isEmpty || working)
        }
    }

    private var passwordSection: some View {
        Section("PDF protegido por senha") {
            if wrongPassword { Text("Senha incorreta. Tente de novo.").foregroundStyle(.red) }
            SecureField("Senha do PDF", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Guardar esta senha para este cartão", isOn: $savePassword)
            Button("Abrir fatura") { openInvoice(password) }.disabled(password.isEmpty || working)
            Text("Em geral é parte do CPF ou a data de nascimento. A senha guardada fica criptografada no servidor, só para este cartão.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func review(_ statement: JSONObject) -> some View {
        let sums = NativeInvoiceSums(statement)
        let closes = abs(sums.computed - total) <= 0.05
        Section("Conferência com o PDF") {
            LabeledContent("Total da fatura (PDF)", value: NativeInvoiceText.money(total))
            LabeledContent("Compras e encargos", value: NativeInvoiceText.money(sums.charges))
            if sums.previous != 0 { LabeledContent("Fatura anterior − pagamentos", value: NativeInvoiceText.money(sums.carried)) }
            LabeledContent("Soma dos lançamentos", value: NativeInvoiceText.money(sums.computed))
            LabeledContent("Lançamentos lidos", value: String(statement.objects("transactions").count))
            if closes { Label("A soma fecha com o total do PDF", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.footnote) }
            else {
                Text("A soma difere do total em " + NativeInvoiceText.money(sums.computed - total) + ". A leitura pode estar incompleta; confira depois no site.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        Section("Mês da fatura") {
            if months.isEmpty {
                Text("Este cartão ainda não tem valor de fatura registrado em nenhum mês. Use Informar fatura no cartão e tente de novo.").foregroundStyle(.secondary)
            }
            ForEach(months) { item in
                Button { month = item.month } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(NativeInvoiceText.month(item.month)).foregroundStyle(.primary)
                            Text("No Saldo Leve: " + NativeInvoiceText.money(item.value) + (item.analyzed ? " · já tem análise" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if matches(item) { Text("confere").font(.caption.bold()).foregroundStyle(.green) }
                        if month == item.month { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }
                }
            }
            if !months.isEmpty && !months.contains(where: matches) {
                Text("Nenhum mês tem fatura de " + NativeInvoiceText.money(total) + " no Saldo Leve. O estudo só é lançado quando o total do PDF é igual ao da fatura do mês; corrija o valor em Informar fatura, se for o caso.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        if selected?.analyzed == true {
            Section("Este mês já tem análise") {
                Picker("O que fazer", selection: $replace) {
                    Text("Adicionar só os novos").tag(false)
                    Text("Substituir").tag(true)
                }.pickerStyle(.segmented)
            }
        }
        Section {
            Button("Lançar estudo da fatura") { save() }.disabled(!canSave)
            Button("Escolher outro PDF") { reset() }
            Text("Não altera o valor da despesa nem do cartão: só registra o estudo (lançamentos, categorias e parcelas).")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: ações

    private func start() async {
        guard !started else { return }
        started = true
        data = fileData
        name = fileName
        working = true
        defer { working = false }
        do {
            let result = try await api.get(JSONObject.self, action: "invoice_cards")
            cards = result.objects("cards").map { NativeInvoiceCard(id: $0.text("id"), name: $0.text("name")) }
            cardID = cards.contains(where: { $0.id == preselectedCard }) ? preselectedCard : (cards.first?.id ?? "")
        } catch { issue = error.localizedDescription }
    }

    private func handlePicked(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): issue = error.localizedDescription
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let bytes = try? Data(contentsOf: url) else { issue = "Não foi possível abrir o arquivo."; return }
            guard bytes.count <= NativeInvoiceLimits.maxBytes else { issue = "O PDF passa de 15 MB. Baixe de novo a fatura no app do banco."; return }
            guard bytes.starts(with: Data("%PDF".utf8)) else { issue = "Escolha um arquivo PDF."; return }
            data = bytes
            name = url.lastPathComponent
            issue = nil
        }
    }

    private func reset() {
        statement = nil
        months = []
        month = ""
        needsPassword = false
        wrongPassword = false
        password = ""
        triedSaved = false
        issue = nil
        if fileData == nil { data = nil; name = "" }
    }

    private func openInvoice(_ pass: String?) {
        run { try await readInvoice(pass) }
    }

    private func readInvoice(_ pass: String?) async throws {
        guard let data, !cardID.isEmpty else { return }
        let engine = reader ?? NativeInvoiceReader(address: api.address)
        reader = engine
        let result = try await engine.read(data, password: pass, fileName: name)
        switch result.text("status") {
        case "password", "wrongPassword":
            if pass == nil && !triedSaved {
                triedSaved = true
                if let saved = try? await api.get(JSONObject.self, action: "invoice_password", query: ["expenseId": cardID]), !saved.text("password").isEmpty {
                    try await readInvoice(saved.text("password"))
                    return
                }
            }
            needsPassword = true
            wrongPassword = result.text("status") == "wrongPassword"
        case "ok":
            needsPassword = false
            wrongPassword = false
            if savePassword, let pass, !pass.isEmpty {
                _ = try? await api.post(action: "invoice_password_save", body: ["expenseId": .string(cardID), "password": .string(pass)])
            }
            var read = result.record("statement")
            var info = "Leitura feita pelo leitor local. Confira os lançamentos."
            do {
                let analysis = try await api.post(action: "invoice_analyze", body: ["expenseId": .string(cardID), "text": result["text"] ?? .string(""), "fileName": .string(name)])
                let ai = analysis.record("statement")
                if analysis["configured"] != .bool(false) && !ai.isEmpty { read = ai; info = "Lida por IA. Confira os lançamentos." }
            } catch { }
            guard !read.objects("transactions").isEmpty else { throw NativeFailure("Não encontrei lançamentos neste PDF.") }
            let list = try await api.get(JSONObject.self, action: "invoice_months", query: ["expenseId": cardID])
            months = list.objects("months").map { NativeInvoiceMonth(month: $0.text("month"), value: $0.decimal("value"), analyzed: $0.flag("analyzed")) }
            let amount = read.decimal("total")
            let matching = months.filter { abs($0.value - amount) < 0.05 }
            let due = NativeInvoiceText.monthBefore(dueDate: read.text("dueDate"))
            month = (matching.first(where: { $0.month == due }) ?? matching.first)?.month ?? ""
            replace = false
            note = info
            statement = read
        default:
            let text = result.text("message")
            throw NativeFailure(text.isEmpty ? "Não consegui ler este PDF." : text)
        }
    }

    private func save() {
        guard var chosen = statement, canSave else { return }
        chosen["month"] = .string(month)
        let mode = selected?.analyzed == true && !replace ? "merge" : "replace"
        run {
            let result = try await api.post(action: "invoice_save", body: ["expenseId": .string(cardID), "statement": .object(chosen), "mode": .string(mode)])
            let text = result.text("message")
            message = text.isEmpty ? "Estudo da fatura lançado." : text
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        issue = nil
        Task {
            defer { working = false }
            do { try await operation() } catch { issue = error.localizedDescription }
        }
    }
}

// MARK: - Panorama

struct NativePanoramaWeb: UIViewRepresentable {
    let address: SiteAddress
    let payload: String

    func makeCoordinator() -> Coordinator { Coordinator(address: address) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.payload = payload
        view.load(URLRequest(url: address.home.deletingLastPathComponent().appendingPathComponent("invoice-panorama.html"), cachePolicy: .reloadIgnoringLocalCacheData))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.payload = payload
        context.coordinator.push()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let address: SiteAddress
        weak var webView: WKWebView?
        var payload = ""
        private var loaded = false
        private var pushed = ""

        init(address: SiteAddress) { self.address = address }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            push()
        }

        func push() {
            guard loaded, let webView, !payload.isEmpty, pushed != payload else { return }
            pushed = payload
            webView.callAsyncJavaScript("window.slPanoramaSet(data); return true;", arguments: ["data": payload], in: nil, in: .page) { _ in }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            decisionHandler(address.contains(url) || url.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
