// Compile the actual event-tap adapter against minimal control endpoints; never install a tap.
enum OptionKeyAction { case openSettings, showHUD, none }
enum Defaults { enum Key { case optionKeyAction }; static subscript(_ key: Key) -> OptionKeyAction { .showHUD } }
@MainActor final class VolumeManager {
    static let shared = VolumeManager()
    func increase(stepDivisor: Float) {}
    func decrease(stepDivisor: Float) {}
    func toggleMuteAction() {}
    func showCurrent() {}
}
@MainActor final class BrightnessManager {
    static let shared = BrightnessManager()
    func setRelative(delta: Float) {}
    func showCurrent() {}
}
@MainActor final class KeyboardBacklightManager {
    static let shared = KeyboardBacklightManager()
    func setRelative(delta: Float) {}
    func showCurrent() {}
}
