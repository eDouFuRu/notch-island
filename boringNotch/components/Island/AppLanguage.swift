import AppKit
import Combine
import SwiftUI

/// Explicit app language; business preference keys and persisted enum values stay unchanged.
@MainActor
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    static let key = "island.language"
    @Published var selection: String {
        didSet {
            UserDefaults.standard.set(selection, forKey: Self.key)
            NotificationCenter.default.post(name: .islandLanguageChanged, object: nil)
        }
    }
    var locale: Locale { Locale(identifier: selection) }
    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        selection = saved == "en" ? "en" : "zh-Hans"
    }
}

extension Notification.Name {
    static let islandLanguageChanged = Notification.Name("IslandLanguageChanged")
    static let islandOpenTimerSettings = Notification.Name("IslandOpenTimerSettings")
}

/// Also usable by AppKit menus and asynchronous service error messages.
func L(_ key: String) -> String {
    let language = UserDefaults.standard.string(forKey: "island.language") == "en" ? "en" : "zh-Hans"
    guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
          let bundle = Bundle(path: path) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: "Localizable")
}

struct IslandLocalization: ViewModifier {
    @ObservedObject private var language = AppLanguage.shared
    func body(content: Content) -> some View {
        content.environment(\.locale, language.locale).id(language.selection)
    }
}

enum IslandIcon: String, CaseIterable {
    case captain, planting, roasting
    var title: String {
        switch self {
        case .captain: return L("Captain Shu")
        case .planting: return L("Planting sweet potatoes")
        case .roasting: return L("Roasting sweet potatoes")
        }
    }
    var assetName: String { "ShuIcon-" + rawValue }
}

@MainActor
final class IslandIconManager: ObservableObject {
    static let shared = IslandIconManager()
    @Published var selected: IslandIcon {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: "island.icon"); apply() }
    }
    private init() {
        selected = IslandIcon(rawValue: UserDefaults.standard.string(forKey: "island.icon") ?? "") ?? .captain
    }
    func apply() { NSApp.applicationIconImage = NSImage(named: selected.assetName) }
}
