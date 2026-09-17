import AppKit
import Foundation
import IOKit.pwr_mgt
import SQLite3

private enum PreferenceKey {
    static let sessionIsActive = "sessionIsActive"
    static let sessionIsIndefinite = "sessionIsIndefinite"
    static let sessionEndDate = "sessionEndDate"
    static let preventScreenSaver = "preventScreenSaver"
    static let codexCompletionDingEnabled = "codexCompletionDingEnabled"
}

private struct CodexTurn: Hashable {
    let threadID: String
    let turnID: String
}

private final class CodexCompletionMonitor {
    private let queue = DispatchQueue(label: "com.andrewmcgrath.stayawake.codex-completion-monitor", qos: .utility)
    private let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)
    private var timer: DispatchSourceTimer?
    private var seenTurns = Set<CodexTurn>()
    private var hasBaseline = false

    private var codexDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }

        hasBaseline = false
        seenTurns.removeAll()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        hasBaseline = false
        seenTurns.removeAll()
    }

    private func poll() {
        guard let currentTurns = completedVisibleTurns() else { return }

        guard hasBaseline else {
            seenTurns = currentTurns
            hasBaseline = true
            return
        }

        let newTurnCount = currentTurns.subtracting(seenTurns).count
        seenTurns = currentTurns
        guard newTurnCount > 0 else { return }

        for index in 0..<newTurnCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(index) * 0.7)) { [weak self] in
                self?.sound?.stop()
                self?.sound?.play()
            }
        }
    }

    private func completedVisibleTurns() -> Set<CodexTurn>? {
        let statePath = codexDirectory.appendingPathComponent("state_5.sqlite").path
        let historyPath = codexDirectory.appendingPathComponent("thread_history_1.sqlite").path

        guard let visibleThreadIDs = queryStrings(
            databasePath: statePath,
            sql: "SELECT id FROM threads WHERE thread_source = 'user' AND preview <> ''"
        ) else {
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(historyPath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 500)

        let sql = """
            SELECT thread_id, turn_id
              FROM thread_turns
             WHERE status = 'completed'
               AND completed_at IS NOT NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var turns = Set<CodexTurn>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadCString = sqlite3_column_text(statement, 0),
                  let turnCString = sqlite3_column_text(statement, 1) else {
                continue
            }

            let threadID = String(cString: threadCString)
            guard visibleThreadIDs.contains(threadID) else { continue }
            turns.insert(CodexTurn(threadID: threadID, turnID: String(cString: turnCString)))
        }

        return turns
    }

    private func queryStrings(databasePath: String, sql: String) -> Set<String>? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 500)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var values = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                values.insert(String(cString: value))
            }
        }
        return values
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Sleep prevention is off", action: nil, keyEquivalent: "")
    private let indefiniteMenuItem = NSMenuItem(title: "Prevent Sleep Indefinitely", action: #selector(startIndefinitely), keyEquivalent: "")
    private let customMenuItem = NSMenuItem(title: "Prevent Sleep for Custom Hours…", action: #selector(promptForCustomHours), keyEquivalent: "")
    private let screenSaverMenuItem = NSMenuItem(title: "Also Prevent Screen Saver & Display Sleep", action: #selector(toggleScreenSaverPrevention), keyEquivalent: "")
    private let codexDingMenuItem = NSMenuItem(title: "Ding When Codex Finishes", action: #selector(toggleCodexCompletionDing), keyEquivalent: "")
    private let stopMenuItem = NSMenuItem(title: "Allow Sleep Now", action: #selector(stopSession), keyEquivalent: "")
    private let codexCompletionMonitor = CodexCompletionMonitor()

    private var systemSleepAssertionID = IOPMAssertionID(0)
    private var displaySleepAssertionID = IOPMAssertionID(0)
    private var userActivityAssertionID = IOPMAssertionID(0)
    private var sessionEndDate: Date?
    private var expiryTimer: Timer?
    private var refreshTimer: Timer?
    private var activityTimer: Timer?

    private var sessionIsActive: Bool {
        systemSleepAssertionID != 0
    }

    private var preventsScreenSaver: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKey.preventScreenSaver) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.preventScreenSaver) }
    }

    private var codexCompletionDingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKey.codexCompletionDingEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.codexCompletionDingEnabled) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.register(defaults: [PreferenceKey.codexCompletionDingEnabled: true])
        configureMenu()
        if codexCompletionDingEnabled {
            codexCompletionMonitor.start()
        }
        restoreSavedSession()
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexCompletionMonitor.stop()
        releaseAllAssertions()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        expireSessionIfNeeded()
        updateUI()
    }

    private func configureMenu() {
        statusMenuItem.isEnabled = false

        [indefiniteMenuItem, customMenuItem, screenSaverMenuItem, codexDingMenuItem, stopMenuItem].forEach {
            $0.target = self
        }

        menu.delegate = self
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(indefiniteMenuItem)
        menu.addItem(customMenuItem)
        menu.addItem(.separator())
        menu.addItem(screenSaverMenuItem)
        menu.addItem(.separator())
        menu.addItem(codexDingMenuItem)
        menu.addItem(.separator())
        menu.addItem(stopMenuItem)
        menu.addItem(.separator())

        let quitMenuItem = NSMenuItem(title: "Quit Stay Awake", action: #selector(quitApp), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
    }

    @objc private func startIndefinitely() {
        startSession(until: nil)
    }

    @objc private func promptForCustomHours() {
        NSApp.activate(ignoringOtherApps: true)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "For example: 2 or 1.5"
        input.stringValue = "2"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "How many hours?"
        alert.informativeText = "Stay Awake will allow your Mac to sleep again when this period ends."
        alert.accessoryView = input
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        while alert.runModal() == .alertFirstButtonReturn {
            guard let hours = parsedHours(from: input.stringValue), hours > 0, hours <= 8_760 else {
                alert.informativeText = "Enter a number greater than 0 and no more than 8,760 hours. Decimals are okay."
                input.selectText(nil)
                continue
            }

            startSession(until: Date().addingTimeInterval(hours * 60 * 60))
            return
        }
    }

    @objc private func toggleScreenSaverPrevention() {
        preventsScreenSaver.toggle()

        if sessionIsActive {
            if preventsScreenSaver {
                guard beginDisplayPrevention() else {
                    preventsScreenSaver = false
                    showError(message: "Stay Awake could not prevent display sleep.")
                    updateUI()
                    return
                }
            } else {
                endDisplayPrevention()
            }
        }

        updateUI()
    }

    @objc private func toggleCodexCompletionDing() {
        codexCompletionDingEnabled.toggle()
        if codexCompletionDingEnabled {
            codexCompletionMonitor.start()
        } else {
            codexCompletionMonitor.stop()
        }
        updateUI()
    }

    @objc private func stopSession() {
        endSession(clearSavedState: true)
    }

    @objc private func quitApp() {
        endSession(clearSavedState: true)
        NSApp.terminate(nil)
    }

    private func parsedHours(from text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current

        if let number = formatter.number(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return number.doubleValue
        }

        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func startSession(until endDate: Date?) {
        endSession(clearSavedState: false)

        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Stay Awake sleep-prevention session" as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            showError(message: "Stay Awake could not create a sleep-prevention session (error \(result)).")
            updateUI()
            return
        }

        systemSleepAssertionID = assertionID
        sessionEndDate = endDate

        if preventsScreenSaver, !beginDisplayPrevention() {
            preventsScreenSaver = false
            showError(message: "Your Mac will stay awake, but Stay Awake could not prevent display sleep.")
        }

        saveSessionState()
        scheduleTimers()
        updateUI()
    }

    @discardableResult
    private func beginDisplayPrevention() -> Bool {
        endDisplayPrevention()

        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Stay Awake screen-saver prevention" as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            return false
        }

        displaySleepAssertionID = assertionID
        declareUserActivity()

        activityTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(refreshUserActivity),
            userInfo: nil,
            repeats: true
        )
        if let activityTimer {
            RunLoop.main.add(activityTimer, forMode: .common)
        }

        return true
    }

    @objc private func refreshUserActivity() {
        guard sessionIsActive, preventsScreenSaver else { return }
        declareUserActivity()
    }

    private func declareUserActivity() {
        _ = IOPMAssertionDeclareUserActivity(
            "Stay Awake screen-saver prevention" as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertionID
        )
    }

    private func endDisplayPrevention() {
        activityTimer?.invalidate()
        activityTimer = nil

        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }

        if userActivityAssertionID != 0 {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = 0
        }
    }

    private func scheduleTimers() {
        expiryTimer?.invalidate()
        refreshTimer?.invalidate()

        if let sessionEndDate {
            let expiryTimer = Timer(fireAt: sessionEndDate, interval: 0, target: self, selector: #selector(sessionExpired), userInfo: nil, repeats: false)
            RunLoop.main.add(expiryTimer, forMode: .common)
            self.expiryTimer = expiryTimer
        }

        let refreshTimer = Timer(timeInterval: 30, target: self, selector: #selector(refreshStatus), userInfo: nil, repeats: true)
        RunLoop.main.add(refreshTimer, forMode: .common)
        self.refreshTimer = refreshTimer
    }

    @objc private func sessionExpired() {
        expireSessionIfNeeded()
    }

    @objc private func refreshStatus() {
        expireSessionIfNeeded()
        updateUI()
    }

    private func expireSessionIfNeeded() {
        if let sessionEndDate, sessionEndDate <= Date() {
            endSession(clearSavedState: true)
        }
    }

    private func endSession(clearSavedState: Bool) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil

        endDisplayPrevention()

        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }

        sessionEndDate = nil

        if clearSavedState {
            clearSessionState()
        }

        updateUI()
    }

    private func releaseAllAssertions() {
        endDisplayPrevention()
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }
    }

    private func saveSessionState() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: PreferenceKey.sessionIsActive)
        defaults.set(sessionEndDate == nil, forKey: PreferenceKey.sessionIsIndefinite)

        if let sessionEndDate {
            defaults.set(sessionEndDate, forKey: PreferenceKey.sessionEndDate)
        } else {
            defaults.removeObject(forKey: PreferenceKey.sessionEndDate)
        }
    }

    private func clearSessionState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: PreferenceKey.sessionIsActive)
        defaults.removeObject(forKey: PreferenceKey.sessionIsIndefinite)
        defaults.removeObject(forKey: PreferenceKey.sessionEndDate)
    }

    private func restoreSavedSession() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PreferenceKey.sessionIsActive) else { return }

        if defaults.bool(forKey: PreferenceKey.sessionIsIndefinite) {
            startSession(until: nil)
            return
        }

        if let endDate = defaults.object(forKey: PreferenceKey.sessionEndDate) as? Date,
           endDate > Date() {
            startSession(until: endDate)
        } else {
            clearSessionState()
        }
    }

    private func updateUI() {
        let active = sessionIsActive
        let iconName = active ? "sun.max.fill" : "moon.zzz"
        let description = active ? "Stay Awake is active" : "Stay Awake is inactive"
        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image

        indefiniteMenuItem.state = active && sessionEndDate == nil ? .on : .off
        customMenuItem.state = active && sessionEndDate != nil ? .on : .off
        screenSaverMenuItem.state = preventsScreenSaver ? .on : .off
        codexDingMenuItem.state = codexCompletionDingEnabled ? .on : .off
        stopMenuItem.isEnabled = active

        if !active {
            statusMenuItem.title = "Sleep prevention is off"
            statusItem.button?.toolTip = "Stay Awake: Off"
        } else if let sessionEndDate {
            let remaining = remainingTimeDescription(until: sessionEndDate)
            statusMenuItem.title = "Awake for \(remaining) more"
            statusItem.button?.toolTip = "Stay Awake: \(remaining) remaining"
        } else {
            statusMenuItem.title = "Awake indefinitely"
            statusItem.button?.toolTip = "Stay Awake: Active indefinitely"
        }

        if active && preventsScreenSaver {
            statusMenuItem.title += " · screen on"
        }
    }

    private func remainingTimeDescription(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        let totalMinutes = max(1, Int(ceil(Double(seconds) / 60)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private func showError(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stay Awake"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
