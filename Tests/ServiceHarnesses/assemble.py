#!/usr/bin/env python3
"""Assemble harnesses around current production implementations, not copied algorithms."""

from pathlib import Path
import sys


def between(text: str, start: str, end: str) -> str:
    if text.count(start) != 1:
        raise ValueError(f"Expected one production marker: {start!r}")
    offset = text.index(start)
    if end not in text[offset:]:
        raise ValueError(f"Missing production end marker: {end!r}")
    return text[offset:text.index(end, offset)]


def without_defaults_import(text: str) -> str:
    if text.count("import Defaults\n") != 1:
        raise ValueError("Expected exactly one Defaults import to substitute")
    return text.replace("import Defaults\n", "", 1)


def main() -> None:
    fixtures = Path(__file__).resolve().parent
    root = fixtures.parent.parent
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)

    media_core = (root / "boringNotch/Interaction/Core/MediaKeyRoutingCore.swift").read_text()
    hud_core = (root / "boringNotch/Interaction/Core/SystemHUDState.swift").read_text()
    brief_core = (root / "boringNotch/Interaction/Core/BriefPresentation.swift").read_text()
    hud = media_core + "\n" + brief_core + "\n" + hud_core + "\n" + without_defaults_import((root / "boringNotch/managers/HUDStateManager.swift").read_text())
    interceptor = media_core + "\n" + without_defaults_import((root / "boringNotch/observers/MediaKeyInterceptor.swift").read_text())
    manager = without_defaults_import((root / "boringNotch/managers/CalendarManager.swift").read_text())
    # Exercise the real persisted selection enum, with only its Defaults marker protocol stubbed.
    selection = between(
        (root / "boringNotch/models/Constants.swift").read_text(),
        "enum CalendarSelectionState:",
        "\nenum HideNotchOption:",
    )
    service = (root / "boringNotch/Providers/CalendarServiceProviding.swift").read_text()
    marker = "// MARK: - Model Extensions"
    if service.count(marker) != 1:
        raise ValueError("CalendarService model-extension marker changed")
    service = service[:service.index(marker)]
    service = service.replace("@preconcurrency import EventKit\n", "", 1)
    scroll = between(
        (root / "boringNotch/components/Calendar/BoringCalendar.swift").read_text(),
        "    private func scrollToRelevantEvent(proxy: ScrollViewProxy)",
        "\n    var body: some View {",
    )
    battery = without_defaults_import((root / "boringNotch/models/BatteryStatusViewModel.swift").read_text())
    sharing_state = (root / "boringNotch/models/SharingStateManager.swift").read_text()
    quick_share = (root / "boringNotch/components/Shelf/Services/QuickShareService.swift").read_text()
    # The real chord monitor plus the real activation rule; only the trust probe is injected.
    chords = "\n".join((root / path).read_text() for path in [
        "boringNotch/Interaction/Core/ShelfChordActivation.swift",
        "boringNotch/Interaction/ShelfKeyboardChords.swift",
    ])
    hardware = "\n".join((root / path).read_text() for path in [
        "boringNotch/Interaction/Core/BriefPresentation.swift",
        "boringNotch/Interaction/Core/SystemHUDState.swift",
        "boringNotch/Interaction/Core/SerialScalarControl.swift",
        "boringNotch/managers/VolumeManager.swift",
        "boringNotch/managers/BrightnessManager.swift",
    ])

    for name, production in [
        ("HUDStateHarness", hud),
        ("CalendarManagerHarness", manager + "\n" + selection),
        ("CalendarServiceHarness", service),
        ("BatteryNotificationHarness", battery),
        ("QuickShareLifecycleHarness", sharing_state + "\n" + quick_share),
        ("HardwareControlsHarness", hardware),
        ("ShelfChordHarness", chords),
        ("MediaKeyInterceptorTypecheck", interceptor),
    ]:
        fixture = (fixtures / f"{name}.swift").read_text()
        (output / f"{name}.swift").write_text(production + "\n" + fixture)

    fixture = (fixtures / "CalendarScrollHarness.swift").read_text()
    marker = "    // PRODUCTION_SCROLL_HELPER"
    if fixture.count(marker) != 1:
        raise ValueError("Calendar scroll fixture insertion marker changed")
    fixture = fixture.replace(marker, scroll)
    event_filter = between(
        (root / "boringNotch/components/Calendar/BoringCalendar.swift").read_text(),
        "    static func filteredEvents(\n",
        "\n    private var filteredEvents:",
    )
    marker = "    // PRODUCTION_EVENT_FILTER"
    if fixture.count(marker) != 1:
        raise ValueError("Calendar event filter fixture insertion marker changed")
    (output / "CalendarScrollHarness.swift").write_text(fixture.replace(marker, event_filter))


if __name__ == "__main__":
    main()
