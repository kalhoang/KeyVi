// SPDX-License-Identifier: GPL-3.0-or-later
//
// The donation block of the About pane (PRD-R56 to PRD-R61; Pa's copy of 15/11/2026, decision S8): on the left the
// thank-you lines, the account details (bank and account number, each selectable with a copy button; never the
// holder's name) and the share text with "Chia sẻ..." and a copy button; on the right the bundled bank VietQR code.
// No prompt, counter or badge anywhere else (PRD-R58); the image is bundled, never fetched.

import AppKit
import AppModel
import ShellCore
import SwiftUI

struct DonationSection: View {
    @ObservedObject var model: SettingsWindowModel
    let info = DonationInfo.standard

    var body: some View {
        let localizer = model.localizer
        SettingsGroup(header: localizer.format(SupportText.donateTitle, model.markedName)) {
            HStack(alignment: .top, spacing: SettingsMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: localizer.format(SupportText.donateBody, model.markedName))
                        Text(verbatim: localizer.format(SupportText.donateHowTo, model.appName))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    DonationAccountDetails(model: model, info: info)
                    DonationShareText(model: model)
                    if let url = info.githubSponsorsURL {
                        Link(destination: url) { Text(verbatim: localizer.string(SupportText.donateSponsors)) }
                            .settingsAccessibility(SupportControl.sponsorsLink, localizer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                QRCodeImage(
                    name: info.vietQRImageName, caption: localizer.string(SupportText.donateVietQR),
                    hint: localizer.string(SupportText.donateScanHint),
                    label: localizer.string(SupportText.donateVietQRImage))
            }
        }
    }
}

/// "Thông tin tài khoản": one row per detail, the value selectable and a copy button after it.
struct DonationAccountDetails: View {
    @ObservedObject var model: SettingsWindowModel
    let info: DonationInfo

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            DonationSubheading(text: localizer.string(SupportText.donateAccountTitle))
            ForEach(info.details) { detail in
                HStack(spacing: 8) {
                    Text(verbatim: localizer.string(detail.label)).foregroundStyle(.secondary)
                    Text(verbatim: detail.value)
                        .font(.body.monospacedDigit().weight(.medium))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    CopyButton(model: model, text: detail.value, control: detail.copyControl)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

/// "Nội dung chia sẻ": the read-only text, then "Chia sẻ..." (the macOS share menu) and the copy button.
struct DonationShareText: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let text = AboutSupportContent.shareText(brand: model.brand, localizer: localizer)
        VStack(alignment: .leading, spacing: 6) {
            DonationSubheading(text: localizer.string(SupportText.donateShareTitle))
            Text(verbatim: text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ShareTextButton(title: localizer.string(SupportText.donateShare), text: text, localizer: localizer)
                CopyButton(model: model, text: text, control: SupportControl.copyShareText)
            }
        }
    }
}

struct DonationSubheading: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
}

/// "Sao chép": puts `text` on the clipboard when clicked (PRD-R48: only on the user's click) and says so in the
/// status line.
struct CopyButton: View {
    @ObservedObject var model: SettingsWindowModel
    let text: String
    let control: SupportControl

    var body: some View {
        let localizer = model.localizer
        Button(action: { model.copyToClipboard(text) }) {
            Text(verbatim: localizer.string(SupportText.donateCopy))
        }
        .controlSize(.small)
        .settingsAccessibility(control, localizer)
    }
}

/// "Chia sẻ...": the macOS share menu under the button (NSSharingServicePicker runs on macOS 12; SwiftUI's ShareLink
/// needs macOS 13).
struct ShareTextButton: View {
    let title: String
    let text: String
    let localizer: Localizer
    @State private var anchor = SharingAnchor()

    var body: some View {
        Button(action: { anchor.share(text) }) { Text(verbatim: title) }
            .controlSize(.small)
            .background(SharingAnchorView(anchor: anchor))
            .settingsAccessibility(SupportControl.share, localizer)
    }
}

/// The AppKit view the share menu opens from.
@MainActor
final class SharingAnchor {
    weak var view: NSView?

    func share(_ text: String) {
        guard let view else { return }
        NSSharingServicePicker(items: [text]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

struct SharingAnchorView: NSViewRepresentable {
    let anchor: SharingAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

/// The QR code is a 1024 px image scaled down smoothly, so its modules stay even at any display scale; it takes the
/// right column at the largest size the minimum window leaves beside the text.
struct QRCodeImage: View {
    static let side: CGFloat = 176
    let name: String
    let caption: String
    let hint: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(name)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.side, height: Self.side)
                .accessibilityLabel(Text(verbatim: label))
            Text(verbatim: caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.side)
    }
}
