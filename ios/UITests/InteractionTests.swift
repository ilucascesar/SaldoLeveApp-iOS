import XCTest

@MainActor
final class InteractionTests: XCTestCase {
    private var recordingFailure = false
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    override func record(_ issue: XCTIssue) {
        guard !recordingFailure else { super.record(issue); return }
        recordingFailure = true
        defer { recordingFailure = false }
        let app = XCUIApplication()
        let target = app.state == .runningForeground ? app : XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("UI_FAILURE_STATE_BEGIN\n" + target.debugDescription + "\nUI_FAILURE_STATE_END")
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = "failure-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        super.record(issue)
    }
    func testAWidgetSettingsAndHomeScreenMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-widgets"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Widgets"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Extra grande vertical")).firstMatch.exists)
        let stepper = app.steppers["widget-row-limit"]
        if !stepper.exists { app.swipeUp() }
        guard stepper.waitForExistence(timeout: 5) else { XCTFail("Missing widget row limit"); return }
        let increment = stepper.buttons["widget-row-limit-Increment"]
        guard increment.waitForExistence(timeout: 5) else { XCTFail("Missing increment control: " + stepper.debugDescription); return }
        increment.tap()
        XCTAssertTrue(app.staticTexts["Até 11 linhas"].exists)
        XCTAssertTrue(increment.isEnabled)
        app.terminate()
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var visibleIcon: XCUIElement?
        for _ in 0..<5 {
            visibleIcon = home.icons.matching(identifier: "SaldoLeve").allElementsBoundByIndex.first { $0.isHittable }
            if visibleIcon != nil { break }
            home.swipeLeft()
        }
        guard let icon = visibleIcon else { XCTFail("SaldoLeve icon is not visible on the Home Screen: " + home.debugDescription); return }
        icon.press(forDuration: 1.5)
        let attachment = XCTAttachment(screenshot: home.screenshot())
        attachment.name = "widget-home-menu"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("WIDGET_HOME_MENU_BEGIN\n" + home.debugDescription + "\nWIDGET_HOME_MENU_END")
        let portrait = home.buttons["Extra Large Portrait widget"].firstMatch
        XCTAssertTrue(portrait.waitForExistence(timeout: 8))
        portrait.tap()
        let addWidget = home.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Add Widget", "Adicionar Widget")).firstMatch
        if addWidget.waitForExistence(timeout: 3) { addWidget.tap() }
        var firstSized: Date?
        let screen = home.frame
        let resized = NSPredicate { _, _ in
            let visible = home.icons.matching(identifier: "SaldoLeve").allElementsBoundByIndex.contains { element in
                let frame = element.frame
                return frame.width > screen.width * 0.75 && frame.height > screen.height * 0.6 && frame.minX >= 0 && frame.maxX <= screen.maxX + 2
            }
            guard visible else { firstSized = nil; return false }
            if firstSized == nil { firstSized = Date() }
            return Date().timeIntervalSince(firstSized!) >= 3
        }
        expectation(for: resized, evaluatedWith: home)
        waitForExpectations(timeout: 30)
        let installed = XCTAttachment(screenshot: home.screenshot())
        installed.name = "widget-portrait-installed"; installed.lifetime = .keepAlways; add(installed)
        print("WIDGET_PORTRAIT_INSTALLED\n" + home.debugDescription)
    }
    func testBSettingsCenterGroupsAndSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Configurações"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["settings-appearance"].exists)
        let widgets = app.buttons["settings-widgets"]
        XCTAssertTrue(widgets.exists); widgets.tap()
        XCTAssertTrue(app.navigationBars["Widgets"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["Configurações"].firstMatch.tap()
        let layout = app.buttons["settings-layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 5)); layout.tap()
        XCTAssertTrue(app.navigationBars["Layout e personalização"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Configurações dos widgets"].exists)
        XCTAssertFalse(app.buttons["Notificações e contador"].exists)
        app.navigationBars.buttons["Configurações"].firstMatch.tap()
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("silêncio")
        XCTAssertTrue(app.buttons["settings-notifications"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings-layout"].exists)
        app.buttons["settings-notifications"].tap()
        XCTAssertTrue(app.navigationBars["Notificações"].waitForExistence(timeout: 8))
    }
    func testUnusualInvoiceReviewFormatsMoneyAndCanCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-review"]
        app.launch()
        let alert = app.alerts["Confira antes de salvar"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1.000,00")).firstMatch.exists)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "100.000,00")).firstMatch.exists)
        alert.buttons["Revisar"].firstMatch.tap()
        XCTAssertFalse(alert.exists)
    }
    func testBirthdayContactsRequireReviewBeforeImport() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-birthdays", "--preview-contacts"]
        app.launch()
        let entry = app.buttons["birthday-import"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20)); entry.tap()
        let load = app.buttons["contacts-load"]
        XCTAssertTrue(load.waitForExistence(timeout: 10)); load.tap()
        let review = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Contato de teste")).firstMatch
        if !review.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Importar 1"].exists)
        app.buttons["Limpar seleção"].tap()
        XCTAssertTrue(app.buttons["Importar 0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Importar 0"].isEnabled)
        app.buttons["Selecionar novos"].tap()
        XCTAssertTrue(app.buttons["Importar 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
    }
    func testRemoteSettingsExposeMenusAndCanCloseWithoutSaving() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-remote"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Menus e textos"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Salvar"].exists)
        XCTAssertTrue(app.textFields["Visão geral"].exists)
        app.navigationBars.buttons["Configurações"].firstMatch.tap()
        app.buttons["Fechar"].firstMatch.tap()
        XCTAssertFalse(app.navigationBars["Menus e textos"].exists)
    }
    func testOfflineEditorIsReadOnlyAndCannotSaveDrafts() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-current-offline"]
        app.launch()
        let title = app.descendants(matching: .any)["task-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.value as? String, "Versão atual no iPhone")
        XCTAssertFalse(title.isEnabled)
        XCTAssertFalse(app.buttons["Salvar"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Somente consulta")).firstMatch.exists || app.staticTexts["Somente consulta"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }
    func testOnlineSaveIsConfirmedOnServer() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-server-save"]
        app.launch()
        let title = app.descendants(matching: .any)["task-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        title.tap(); title.typeText(" atualizado")
        let status = app.descendants(matching: .any)["task-save-status"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Salvo na sua conta"), evaluatedWith: status)
        waitForExpectations(timeout: 35)
        XCTAssertTrue((title.value as? String ?? "").contains("atualizado"))
        XCTAssertEqual(app.alerts.count, 0)
    }
    func testServerWinsStaleWriteWithoutDraftOrReplay() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-sync-overlap"]
        app.launch()
        let title = app.descendants(matching: .any)["task-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.value as? String, "Título editado na web")
        title.tap(); title.typeText(" local")
        expectation(for: NSPredicate(format: "value == %@", "Título editado na web"), evaluatedWith: title)
        waitForExpectations(timeout: 35)
        XCTAssertTrue(app.descendants(matching: .any)["task-sync-notice"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Revisar alterações"].exists)
        XCTAssertTrue(app.staticTexts["Envios ao servidor: 1"].exists)
        XCTAssertEqual(app.alerts.count, 0)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
    func testComputerUpdateReplacesOpenEditorWithoutSubmittingLocalContent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-sync-live"]
        app.launch()
        let update = app.buttons["test-server-change"]
        XCTAssertTrue(update.waitForExistence(timeout: 20)); update.tap()
        let title = app.descendants(matching: .any)["task-title"].firstMatch
        expectation(for: NSPredicate(format: "value == %@", "Atualização do computador"), evaluatedWith: title)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Envios ao servidor: 0"].exists)
    }
    func testInstallmentShowsBothAmountsAndUpdatesDiscount() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-payments"]
        app.launch()
        let entry = app.buttons["Pagar / antecipar parcelas"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 20)); entry.tap()
        let original = app.textFields["installment-original-parcela1"]
        let paid = app.textFields["installment-paid-parcela1"]
        XCTAssertTrue(original.waitForExistence(timeout: 10)); XCTAssertTrue(paid.exists)
        paid.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap(); let paidCount = (paid.value as? String ?? "").count
        paid.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: paidCount) + "650,00")
        let discount = app.staticTexts["installment-discount-parcela1"]
        XCTAssertTrue(discount.label.contains("350,00"))
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap(); let originalCount = (original.value as? String ?? "").count
        original.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalCount) + "1200,00")
        XCTAssertEqual(paid.value as? String, "650,00"); XCTAssertTrue(discount.label.contains("550,00"))
        app.buttons["Pronto"].firstMatch.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Cancelar"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
    func testWorkspaceSwitchesAndEdgeDrawerWith5000Tasks() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--ui-stress"]
        app.launch()
        let calendar = app.buttons["workspace-calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 20))
        for _ in 0..<3 {
            let start = Date(); calendar.tap()
            XCTAssertTrue(app.descendants(matching: .any)["calendar-grid"].firstMatch.waitForExistence(timeout: 5))
            print("5000 tasks: calendar visible after \(Date().timeIntervalSince(start)) seconds including test automation.")
            app.buttons["workspace-habits"].tap()
            XCTAssertTrue(app.staticTexts["Meus hábitos"].waitForExistence(timeout: 5))
            app.buttons["workspace-list"].tap()
        }
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 5, dy: 0))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        left.press(forDuration: 0.05, thenDragTo: right)
        let menu = app.buttons["Menu do aplicativo"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "A swipe from the left edge opens the task drawer")
        right.press(forDuration: 0.05, thenDragTo: left)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: menu)
        waitForExpectations(timeout: 5)
    }
    func testFourColumnCardsHaveNativeContextActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--preview-columns4"]
        app.launch()
        let card = app.descendants(matching: .any)["expense-card-1"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        card.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Abrir detalhes"].waitForExistence(timeout: 5), "Holding an expense exposes native context actions")
        XCTAssertTrue(app.buttons["Novo gasto"].exists)
    }
}
