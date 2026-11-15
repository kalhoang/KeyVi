# 0305. UI framework: AppKit status item, SwiftUI windows

- Status: accepted, 2026-11-13
- Requirements: PRD-R9-R13, PRD-R24, PRD-R28, PRD-R40, PRD-R63, PRD-R66, PRD-R67, PLT-R905, M1 (memory)
- Context: The menu must open within 100 ms and never block typing (PRD-R13); icons are monochrome templates
  with VoiceOver labels (PRD-R10); the switch HUD and the capture HUD are non-activating panels above
  full-screen apps (PRD-R12, PLT-R905); Settings and onboarding are normal windows with full keyboard
  navigation. `MenuBarExtra` (SwiftUI) gives little control over menu rebuilding, status-item accessibility
  and click-to-toggle (D16).

## Decision

- `NSStatusItem` + `NSMenu` (AppKit) for the menu bar: the menu is rebuilt in `menuNeedsUpdate(_:)` from a
  `MenuModel` value (ShellCore), so it always reflects the latest state and language, and the status button's
  `accessibilityLabel` follows `StatusIconState`. Click-to-toggle uses the button action with the menu shown
  on secondary click (D16).
- `NSPanel` with `.nonactivatingPanel`, `.canJoinAllSpaces`, `.fullScreenAuxiliary` and `.statusBar` level for
  the switch HUD and the capture HUD; content in SwiftUI via `NSHostingView`. The HUD posts
  `NSAccessibility.post(element:notification: .announcementRequested)`.
- Settings (five panes), onboarding (640 x 480), macros editor, Apps pane, bug report, diagnostics window,
  latency probe window and capture review are SwiftUI views hosted in `NSWindow`s owned by small AppKit
  window controllers (frame autosave for PRD-R28, no floating level).
- View models are `@MainActor @Observable` types; their logic lives in ShellCore where it is testable.

## Consequences

- No SwiftUI `App` lifecycle: `AppMain` is an `NSApplicationDelegate` with `.accessory` activation policy,
  which keeps launch time and memory at rest low (S1, M1; VERIFY M1 against a measured baseline in the first
  sprint). *(Amended 15/11/2026, PRD-R28, PLT-R201.)* While a user window is open (shown or minimized) the policy
  is `.regular`, so the window is in the Dock and the Command+Tab switcher, and `MainMenuController` installs the
  app, Edit and Window menus; `WindowPresenceController` returns to `.accessory` one main-queue turn after the last
  such window closes. The rule and its timing are ShellCore's `AppPresenceCoordinator`; the policy changes in
  `NSApplication.bringToFront()` before activation and on window notifications of the whole process.
- Text fields inside the app (practice field, macro editor) are ordinary fields; the tap treats the app itself
  like any other focus owner, except that hotkeys are suspended while the hotkey recorder is active.
