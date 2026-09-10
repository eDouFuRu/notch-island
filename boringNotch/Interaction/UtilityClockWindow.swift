import AppKit
import Combine
import SwiftUI
import UserNotifications

enum UtilityWindowPage: String, CaseIterable, Identifiable {
    case stopwatch, timer, alarm
    var id: String { rawValue }
    var title: String {
        switch self { case .stopwatch: return "Stopwatch"; case .timer: return "Timer"; case .alarm: return "Alarm" }
    }
}

@MainActor final class UtilityClockStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UtilityClockStore()
    private static let storageKey = "island.utilityClocks.v1"
    @Published private(set) var snapshot: UtilityClockSnapshot
    @Published private(set) var noticeKey = ""
    @Published private(set) var now = Date()
    private var ticker: Timer?
    private var schedulingTasks: [UtilityNotificationKind: Task<Void, Never>] = [:]
    private var scheduleTokens: [UtilityNotificationKind: UUID] = [:]

    private override init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let state = try? JSONDecoder().decode(UtilityClockSnapshot.self, from: data) { snapshot = state }
        else { snapshot = UtilityClockSnapshot() }
        super.init()
        UNUserNotificationCenter.current().delegate = self
        refresh()
        restorePendingNotifications()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common); ticker = timer
    }
    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
    func refresh(at timestamp: Date = Date()) {
        now = timestamp
        let timerDone = snapshot.countdown.settle(at: now)
        let alarmDone = snapshot.settleAlarm(at: now)
        if timerDone || alarmDone {
            // Keep the session's request ID until cancel/new session. Completion must not
            // revoke a just-expired request while macOS is preparing to deliver it.
            noticeKey = timerDone ? "Timer finished" : "Your alarm is ringing"
            save()
        }
    }
    func toggleStopwatch() {
        let timestamp = Date()
        refresh(at: timestamp)
        if snapshot.stopwatch.startedAt == nil { snapshot.stopwatch.start(at: timestamp) }
        else { snapshot.stopwatch.pause(at: timestamp) }
        save()
    }
    func lap() {
        let timestamp = Date()
        refresh(at: timestamp)
        snapshot.stopwatch.lap(at: timestamp); save()
    }
    func resetStopwatch() { refresh(); snapshot.stopwatch.reset(); save() }
    func startTimer(seconds: Double) {
        // A stale one-second UI tick plus ceil could initially render five seconds as six.
        // All transitions use one timestamp for both the displayed clock and timer core.
        let timestamp = Date()
        refresh(at: timestamp)
        guard !snapshot.countdown.isActive, snapshot.countdown.start(seconds: seconds, at: timestamp) else { return }
        remove(.timer); save(); schedule(.timer, at: snapshot.countdown.deadline!)
    }
    func toggleTimer() {
        let timestamp = Date()
        refresh(at: timestamp)
        if snapshot.countdown.deadline != nil {
            snapshot.countdown.pause(at: timestamp); remove(.timer)
        } else if snapshot.countdown.pausedRemaining != nil {
            snapshot.countdown.resume(at: timestamp)
            if let date = snapshot.countdown.deadline { schedule(.timer, at: date) }
        }
        save()
    }
    func cancelTimer() { refresh(); snapshot.countdown.cancel(); remove(.timer); save() }
    func setAlarm(_ date: Date) {
        let timestamp = Date()
        refresh(at: timestamp)
        guard let minute = UtilityAlarmInput.submission(date, at: timestamp) else {
            noticeKey = "Choose a future alarm time."; return
        }
        remove(.alarm)
        snapshot.alarmDate = minute; snapshot.alarmCompleted = false; save(); schedule(.alarm, at: minute)
    }
    func cancelAlarm() { refresh(); snapshot.alarmDate = nil; snapshot.alarmCompleted = false; remove(.alarm); save() }
    private func remove(_ kind: UtilityNotificationKind) {
        schedulingTasks.removeValue(forKey: kind)?.cancel()
        scheduleTokens.removeValue(forKey: kind)
        if let id = snapshot.invalidateNotification(for: kind) {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        }
        noticeKey = ""
    }

    private func owns(_ kind: UtilityNotificationKind, id: String, token: UUID) -> Bool {
        snapshot.notificationID(for: kind) == id && scheduleTokens[kind] == token
    }

    private func restorePendingNotifications() {
        // Startup may recover a snapshot saved before add() finished. Check permission
        // passively and repair only future sessions; never replay an already completed one.
        if let date = snapshot.countdown.deadline, date > now { schedule(.timer, at: date, requestPermission: false) }
        if let date = snapshot.alarmDate, date > now { schedule(.alarm, at: date, requestPermission: false) }
        Task { @MainActor [weak self] in
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            guard let self else { return }
            // Read ownership after the suspension: a new session may have started meanwhile.
            let stale = self.snapshot.staleNotificationIDs(in: pending.map(\.identifier))
            if !stale.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale) }
        }
    }

    private func schedule(_ kind: UtilityNotificationKind, at date: Date, requestPermission: Bool = true) {
        schedulingTasks.removeValue(forKey: kind)?.cancel()
        let id = snapshot.ensureNotificationID(for: kind)
        let token = UUID()
        scheduleTokens[kind] = token
        noticeKey = ""
        save() // The stable session ID must survive quitting while authorization/add awaits.
        schedulingTasks[kind] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.scheduleTokens[kind] == token { self.schedulingTasks[kind] = nil } }
            let center = UNUserNotificationCenter.current()
            do {
                let allowed: Bool
                if requestPermission {
                    allowed = try await center.requestAuthorization(options: [.alert, .sound])
                } else {
                    let settings = await center.notificationSettings()
                    allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
                }
                guard !Task.isCancelled, self.owns(kind, id: id, token: token) else { return }
                guard allowed else {
                    self.noticeKey = "Notifications are off. The tool will still show completion while the app is running."
                    return
                }
                let interval = date.timeIntervalSinceNow
                if interval <= 0 { self.refresh() }
                let content = UNMutableNotificationContent()
                content.title = L(kind == .timer ? "Timer finished" : "Your alarm is ringing")
                content.body = L("Open the island tools to view or start another session.")
                content.sound = .default
                content.userInfo = ["islandUtilityPage": kind.rawValue]
                // If authorization took longer than the countdown, deliver this still-owned
                // session immediately, instead of losing a one-second timer's notification.
                let trigger = interval > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false) : nil
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                try await center.add(request)
                guard !Task.isCancelled, self.owns(kind, id: id, token: token) else {
                    // An old A cannot remove or replace a newer B: their request IDs differ.
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    return
                }
                if date > Date() { self.noticeKey = "System notification scheduled. Sound follows macOS notification settings." }
            } catch {
                guard !Task.isCancelled, self.owns(kind, id: id, token: token) else { return }
                self.noticeKey = "Could not schedule the system notification. Check notification settings."
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["islandUtilityPage"] as? String
        Task { @MainActor in
            if let raw, let page = UtilityWindowPage(rawValue: raw) { UtilityClockWindow.shared.show(page) }
            completionHandler()
        }
    }
}

@MainActor final class UtilityClockWindow: NSWindowController, NSWindowDelegate, ObservableObject {
    static let shared = UtilityClockWindow()
    @Published var page = UtilityWindowPage.stopwatch
    @Published private(set) var presentationID = UUID()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.identifier = NSUserInterfaceItemIdentifier("IslandUtilityClockWindow")
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: UtilityClockView(controller: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ page: UtilityWindowPage) {
        self.page = page; window?.title = L(page.title)
        UtilityClockStore.shared.refresh()
        presentationID = UUID() // Also signals reopening the already-selected page.
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if SettingsWindowController.shared.window?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct UtilityClockView: View {
    @ObservedObject var controller: UtilityClockWindow
    @ObservedObject private var store = UtilityClockStore.shared
    @ObservedObject private var language = AppLanguage.shared
    @State private var minutes = "5"
    @State private var seconds = "0"
    @State private var alarm = UtilityAlarmInput.defaultDraft(at: Date())
    @State private var earliestAlarmMinute = UtilityAlarmInput.firstFutureMinute(after: Date())
    var body: some View {
        VStack(spacing: 18) {
            Picker(L("Clock tool"), selection: $controller.page) {
                ForEach(UtilityWindowPage.allCases) { Text(L($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            switch controller.page {
            case .stopwatch: stopwatch
            case .timer: countdown
            case .alarm: alarmView
            }
            Spacer(minLength: 0)
            if !store.noticeKey.isEmpty {
                Text(L(store.noticeKey)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(24).frame(width: 440, height: 420)
            .environment(\.locale, language.locale)
            .onChange(of: controller.page) {
                controller.window?.title = L(controller.page.title)
                prepareAlarmDraft()
            }
            .onChange(of: controller.presentationID) { prepareAlarmDraft() }
    }
    private var stopwatch: some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                Text(Self.clock(store.snapshot.stopwatch.elapsed(at: context.date), hundredths: true))
                    .font(.system(size: 42, weight: .light, design: .monospaced))
            }
            HStack {
                Button(L(store.snapshot.stopwatch.startedAt == nil ? "Start / Resume" : "Pause")) { store.toggleStopwatch() }
                    .buttonStyle(.borderedProminent)
                Button(L("Lap")) { store.lap() }.disabled(store.snapshot.stopwatch.startedAt == nil)
                Button(L("Reset")) { store.resetStopwatch() }
            }
            ScrollView {
                ForEach(Array(store.snapshot.stopwatch.laps.enumerated()), id: \.offset) { index, lap in
                    HStack { Text("\(store.snapshot.stopwatch.laps.count - index)"); Spacer(); Text(Self.clock(lap, hundredths: true)).monospacedDigit() }
                        .padding(.vertical, 3)
                }
            }.frame(maxHeight: 180)
        }
    }
    private var countdown: some View {
        VStack(spacing: 16) {
            Text(Self.clock(store.snapshot.countdown.remaining(at: store.now), hundredths: false))
                .font(.system(size: 42, weight: .light, design: .monospaced))
            if store.snapshot.countdown.completed { Label(L("Timer finished"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                TextField(L("Minutes"), text: $minutes).frame(width: 55)
                Text(L("Minutes"))
                TextField(L("Seconds"), text: $seconds).frame(width: 55)
                Text(L("Seconds"))
            }.textFieldStyle(.roundedBorder).disabled(store.snapshot.countdown.isActive)
            if store.snapshot.countdown.isActive {
                HStack {
                    Button(L(store.snapshot.countdown.deadline == nil ? "Resume" : "Pause")) { store.toggleTimer() }.buttonStyle(.borderedProminent)
                    Button(L("Cancel timer")) { store.cancelTimer() }
                }
            } else {
                Button(L("Start timer")) {
                    if let duration = UtilityTimerInput.duration(minutes: minutes, seconds: seconds) { store.startTimer(seconds: duration) }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(UtilityTimerInput.duration(minutes: minutes, seconds: seconds) == nil)
            }
            Text(L("1 second to 24 hours. Closing this window keeps the timer running.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var alarmView: some View {
        VStack(spacing: 18) {
            Image(systemName: "alarm.fill").font(.system(size: 46)).foregroundStyle(.orange)
            if let scheduled = store.snapshot.alarmDate {
                Text(scheduled, format: .dateTime.month().day().hour().minute()).font(.title2)
                Button(L("Cancel alarm")) { store.cancelAlarm() }
            } else {
                if store.snapshot.alarmCompleted { Text(L("Your alarm is ringing")).foregroundStyle(.orange) }
                DatePicker(L("Alarm time"), selection: Binding(get: { alarm }, set: {
                    alarm = UtilityAlarmInput.minuteStart($0)
                }), in: earliestAlarmMinute..., displayedComponents: [.date, .hourAndMinute])
                    .onAppear { prepareAlarmDraft() }
                Button(L("Set alarm")) {
                    store.setAlarm(UtilityAlarmInput.minuteStart(alarm))
                }.buttonStyle(.borderedProminent)
                    .disabled(UtilityAlarmInput.submission(alarm, at: store.now) == nil)
            }
            Text(L("One-time alarm. macOS notifications require permission and follow Focus settings; a sleeping Mac may deliver after waking."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
    private func prepareAlarmDraft() {
        guard controller.page == .alarm else { return }
        let timestamp = Date()
        store.refresh(at: timestamp)
        guard store.snapshot.alarmDate == nil else { return }
        alarm = UtilityAlarmInput.draftOnEntry(alarm, at: timestamp)
        // Keep this DatePicker bound stable during editing. A later clock tick may
        // disable submission, but must not clamp or silently advance the draft.
        earliestAlarmMinute = UtilityAlarmInput.firstFutureMinute(after: timestamp)
    }
    private static func clock(_ elapsed: TimeInterval, hundredths: Bool) -> String {
        let ticks = max(0, Int((elapsed * (hundredths ? 100 : 1)).rounded(hundredths ? .down : .up)))
        let whole = hundredths ? ticks / 100 : ticks
        let time = String(format: "%02d:%02d:%02d", whole / 3_600, whole / 60 % 60, whole % 60)
        return hundredths ? time + String(format: ".%02d", ticks % 100) : time
    }
}
