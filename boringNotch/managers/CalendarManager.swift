//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var permissionErrorMessage: String?
    private var eventRequestGeneration: UInt64 = 0
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
        await updateEvents()
    }

    /// Passive refresh. Merely opening settings or a calendar view must not prompt.
    func checkCalendarAuthorization() async {
        await reloadCalendarAndReminderLists()
    }

    func checkReminderAuthorization() async {
        await reloadCalendarAndReminderLists()
    }

    func requestCalendarAccess() async {
        await requestAccess(to: .event)
    }

    func requestReminderAccess() async {
        await requestAccess(to: .reminder)
    }

    private func requestAccess(to type: EKEntityType) async {
        guard !isRequestingAccess else { return }
        let status = EKEventStore.authorizationStatus(for: type)
        guard status == .notDetermined || status == .writeOnly else {
            await reloadCalendarAndReminderLists()
            return
        }
        isRequestingAccess = true
        permissionErrorMessage = nil
        defer { isRequestingAccess = false }
        do {
            _ = try await calendarService.requestAccess(to: type)
        } catch {
            permissionErrorMessage = type == .event
                ? "Unable to request calendar access."
                : "Unable to request reminders access."
        }
        await reloadCalendarAndReminderLists()
    }

    var hasCalendarAccess: Bool { calendarAuthorizationStatus == .fullAccess }
    var hasReminderAccess: Bool { reminderAuthorizationStatus == .fullAccess }
    var hasAnyAccess: Bool { hasCalendarAccess || hasReminderAccess }
    var hasSelectedCalendars: Bool { !selectedCalendars.isEmpty }

    func updateSelectedCalendars() {
        selectedCalendars = allCalendars.filter { getCalendarSelected($0) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        switch Defaults[.calendarSelectionState] {
        case .all:
            return true
        case .selected(let identifiers):
            return identifiers.contains(calendar.id)
        }
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            let allIdentifiers = Set(allCalendars.map { $0.id })
            // An explicit empty selection must stay empty. It is never shorthand for "all".
            selectionState = !allIdentifiers.isEmpty && identifiers == allIdentifiers
                ? .all : .selected(identifiers)
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        eventRequestGeneration &+= 1
        let generation = eventRequestGeneration
        let calendarIDs = selectedCalendars.map { $0.id }
        guard !calendarIDs.isEmpty else {
            events = []
            return
        }
        let day = currentWeekStartDate
        let eventsResult = await calendarService.events(
            from: day,
            to: Calendar.current.date(byAdding: .day, value: 1, to: day)!,
            calendars: calendarIDs
        )
        // A slower request for a previous date/selection must not overwrite the latest result.
        guard generation == eventRequestGeneration else { return }
        events = eventsResult
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        await updateEvents()
    }
}
