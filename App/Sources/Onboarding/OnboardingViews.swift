// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Onboarding layout (PRD-R40): one screen at a time with the footer (Quay lại, Bỏ qua, primary). Strings are
// resolved through the selected language's `Localizer` and rendered with `Text(verbatim:)` (ADR 0310). Every
// control has a VoiceOver label and hint from the Onboarding table (PRD-R66) and is reachable by keyboard with
// the system focus ring (PRD-R67).

import AppModel
import ShellCore
import SwiftUI

struct OnboardingRootView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 40)
                .padding(.top, 32)
            Divider()
            OnboardingFooter(model: model)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(
            width: OnboardingWindowController.contentSize.width, height: OnboardingWindowController.contentSize.height
        )
        // PRD-R67: with Reduce Motion on, no implicit SwiftUI animation runs anywhere in the window.
        .respectsReduceMotion()
        .sheet(isPresented: $model.showPermissionHelp) { PermissionHelpSheet(model: model).respectsReduceMotion() }
    }

    @ViewBuilder private var screen: some View {
        switch model.flow.screen {
        case .welcome: WelcomeScreen(model: model)
        case .permission: PermissionScreen(model: model)
        case .typingMethod: TypingMethodScreen(model: model)
        case .switching: SwitchingScreen(model: model)
        case .conflicts: ConflictsScreen(model: model)
        case .importFrom: ImportScreen(model: model)
        case .tryIt: TryItScreen(model: model)
        case .done: DoneScreen(model: model)
        }
    }
}

struct OnboardingFooter: View {
    let model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        HStack {
            if model.flow.canGoBack {
                Button(action: model.back) { Text(verbatim: localizer.string(CommonText.back)) }
                    .onboardingAccessibility(.back, localizer)
            }
            Spacer()
            if model.showsSkip {
                Button(action: model.skip) { Text(verbatim: model.skipTitle) }
                    .onboardingAccessibility(model.skipControl, localizer, label: model.skipTitle)
            }
            Button(action: model.primary) { Text(verbatim: model.primaryTitle) }
                .keyboardShortcut(.defaultAction)
                .onboardingAccessibility(model.primaryControl, localizer, label: model.primaryTitle)
        }
    }
}

struct ScreenTitle: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.title.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 8)
    }
}

struct WelcomeScreen: View {
    let model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(text: localizer.format(OnboardingText.welcomeTitle, model.appName))
            Text(verbatim: localizer.string(OnboardingText.welcomeBody)).font(.title3)
            Spacer()
            Text(verbatim: localizer.format(OnboardingText.welcomeFootnote, model.appName))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct PermissionScreen: View {
    let model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        let content = model.permissionContent
        VStack(alignment: .leading, spacing: 12) {
            ScreenTitle(text: content.title)
            if let lost = content.lostNotice { Text(verbatim: lost).fontWeight(.medium) }
            Text(verbatim: content.body)
            ForEach(content.bullets, id: \.self) { bullet in
                Label {
                    Text(verbatim: bullet)
                } icon: {
                    Image(systemName: "checkmark.shield").accessibilityHidden(true)
                }
            }
            HStack(alignment: .center, spacing: 16) {
                PermissionIllustration(label: localizer.string(OnboardingText.permissionIllustration))
                Text(verbatim: content.instruction).font(.callout)
            }
            PermissionStatusView(model: model, content: content)
            Button(action: { model.showPermissionHelp = true }) { Text(verbatim: content.helpLink) }
                .buttonStyle(.link)
                .onboardingAccessibility(.permissionHelp, localizer, label: content.helpLink)
        }
    }
}

/// "Đã cấp quyền" with a check mark, or the waiting line, plus the stale and Input Monitoring notices.
struct PermissionStatusView: View {
    let model: OnboardingModel
    let content: PermissionScreenContent

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 8) {
            if model.flow.permissionGranted {
                Label {
                    Text(verbatim: localizer.string(OnboardingText.permissionGranted)).fontWeight(.semibold)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                }
            } else {
                Label {
                    Text(verbatim: localizer.string(OnboardingText.permissionWaiting)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "hourglass").accessibilityHidden(true)
                }
            }
            if let stale = content.staleNotice { Text(verbatim: stale).font(.callout) }
            if let notice = content.inputMonitoringNotice { InputMonitoringNotice(model: model, notice: notice) }
        }
    }
}

struct InputMonitoringNotice: View {
    let model: OnboardingModel
    let notice: String

    var body: some View {
        let localizer = model.localizer
        let content = model.permissionContent
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: notice).font(.callout)
            HStack {
                if let open = content.openInputMonitoringButton {
                    Button(action: model.openInputMonitoringPane) { Text(verbatim: open) }
                        .onboardingAccessibility(.openInputMonitoringPane, localizer, label: open)
                }
                if let relaunch = content.relaunchButton {
                    Button(action: model.relaunch) { Text(verbatim: relaunch) }
                        .onboardingAccessibility(.relaunch, localizer, label: relaunch)
                }
            }
        }
    }
}

/// Placeholder illustration of the System Settings switch (VERIFY with Pa: replace with a designed asset). A short
/// loop that becomes a static "on" switch when Reduce Motion is on (PRD-R40, PRD-R67). The switch is rebuilt when
/// the setting changes, so turning Reduce Motion on while the screen is open stops the loop at once.
struct PermissionIllustration: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IllustrationSwitch()
            .id(reduceMotion)
            .frame(width: 52, height: 30)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label))
    }
}

/// The drawn switch: shape and position carry the state; the outline keeps it visible in Increase Contrast. It loops
/// only while Reduce Motion is off; the parent rebuilds it when the setting changes.
private struct IllustrationSwitch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOn = false

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
            Circle().fill(.white).padding(3).shadow(radius: 1)
        }
        .overlay(Capsule().strokeBorder(.separator))
        .onAppear {
            guard !reduceMotion else {
                isOn = true
                return
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isOn = true }
        }
    }
}

struct TypingMethodScreen: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(text: localizer.string(OnboardingText.methodTitle))
            HStack(spacing: 16) {
                MethodCard(model: model, method: .telex)
                MethodCard(model: model, method: .vni)
            }
            PracticeField(model: model, text: $model.practiceText, control: .practiceField)
        }
    }
}

struct MethodCard: View {
    let model: OnboardingModel
    let method: TypingMethod
    @FocusState private var focused: Bool

    var body: some View {
        let localizer = model.localizer
        let selected = model.method == method
        Button(action: { model.select(method) }) {
            MethodCardLabel(localizer: localizer, method: method, selected: selected, focused: focused)
        }
        .buttonStyle(.plain)
        // PRD-R67: a plain-style card draws its own keyboard focus ring (MethodCardLabel), always visible.
        .focused($focused)
        .focusEffectDisabled()
        .onboardingAccessibility(method == .telex ? .methodTelex : .methodVNI, localizer)
        .accessibilityValue(Text(verbatim: selected ? localizer.string(OnboardingText.methodSelected) : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Card face: title, example and the selection mark. Selection is a symbol and a thicker border, never colour
/// alone; keyboard focus is the system focus-ring colour drawn outside the card (PRD-R67).
struct MethodCardLabel: View {
    let localizer: Localizer
    let method: TypingMethod
    let selected: Bool
    var focused = false

    var body: some View {
        let title = localizer.string(method == .telex ? OnboardingText.methodTelexTitle : OnboardingText.methodVNITitle)
        let example = localizer.string(
            method == .telex ? OnboardingText.methodTelexExample : OnboardingText.methodVNIExample)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title).font(.headline)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
            }
            Text(verbatim: example).font(.callout.monospaced())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(
                selected ? Color.accentColor : .secondary, lineWidth: selected ? 3 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .padding(-3)
                .opacity(focused ? 1 : 0))
    }
}

/// Live practice field (PRD-R40 screens 3 and 7). Typed text stays in memory only (PLT-R901).
struct PracticeField: View {
    let model: OnboardingModel
    @Binding var text: String
    let control: OnboardingControl

    var body: some View {
        let localizer = model.localizer
        TextField(text: $text, axis: .vertical) {
            Text(verbatim: localizer.string(OnboardingText.practicePlaceholder))
        }
        .textFieldStyle(.roundedBorder)
        .lineLimit(3, reservesSpace: true)
        .onboardingAccessibility(control, localizer)
    }
}

extension View {
    /// VoiceOver label and hint from the Onboarding table (PRD-R66). `label` overrides the control's label key
    /// for buttons whose visible title is the better label.
    func onboardingAccessibility(_ control: OnboardingControl, _ localizer: Localizer, label: String? = nil)
        -> some View
    {
        accessibilityLabel(Text(verbatim: label ?? localizer.string(control.accessibilityLabelKey, table: .onboarding)))
            .accessibilityHint(Text(verbatim: localizer.string(control.accessibilityHintKey, table: .onboarding)))
    }
}
