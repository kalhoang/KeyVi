# Managed Macs: privacy permissions for IT administrators

Audience: administrators who deploy {{AppName}} with a device management (MDM) service. Specification: PLT-R760, with PLT-R701 to PLT-R703 (permissions) and PLT-R750 to PLT-R752 (signing identity).

{{AppName}} is a Vietnamese input method that runs as a menu-bar app with a keyboard event tap. It needs macOS privacy permissions to read keystrokes and type the corrected text. On a managed Mac, a Privacy Preferences Policy Control (PPPC) profile can pre-approve them for the app's code requirement. On an unmanaged Mac, the user approves them once in System Settings, guided by the app (section 5).

Sources: Apple's device management reference for the `PrivacyPreferencesPolicyControl` payload and Apple's deployment guide for macOS 27. Pane names and the macOS 27 behaviour are marked VERIFY: check them against Apple's current documentation and your MDM vendor's for the macOS version you deploy.

## 1. Services the app needs

Payload type: `com.apple.TCC.configuration-profile-policy` (device channel, user-approved MDM enrollment).

| PPPC service | Why the app needs it | Value to set |
|---|---|---|
| `Accessibility` | The active keyboard event tap and focus queries through the accessibility API (PLT-R701) | `Authorization` = `Allow` (on macOS 27 see section 3) |
| `PostEvent` | Posting the corrected text as keyboard events; the app checks it with `CGPreflightPostEventAccess()` (PLT-R701) | `Authorization` = `Allow` |
| `ListenEvent` | Input Monitoring, requested only when macOS needs it for the tap (PLT-R702) | `Authorization` = `AllowStandardUserToSetSystemService` |

Notes:

- A profile cannot grant `ListenEvent`; Apple allows only `Deny` or `AllowStandardUserToSetSystemService`, which lets a standard (non-admin) user approve it when macOS asks.
- Do not set `Deny` for any of the three services. The app then passes every key through unchanged (fail-open, PLT-R730), so Vietnamese input does not work.
- The app needs nothing else (PLT-R703): no Apple Events (Automation), Screen Recording, Full Disk Access, Contacts, Bluetooth, local network or camera. A profile that grants more than the table above is wider than necessary.

## 2. Identity and code requirement

Each service entry identifies the app the same way:

- `Identifier`: the release bundle ID, `vn.kal.{{app-slug}}`. The authoritative value is `APP_BUNDLE_ID_RELEASE` in `scripts/brand.env`. Development builds use a separate `.dev` bundle ID and Apple Development signing (PLT-R751); a profile for the release app does not cover them.
- `IdentifierType`: `bundleID`.
- `CodeRequirement`: the default designated requirement of a Developer ID signed app (bundle ID plus team anchor, PLT-R750):

```text
identifier "vn.kal.{{app-slug}}" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = TEAM_ID
```

`TEAM_ID` is the Apple Team ID of the Developer ID certificate that signs the app. Do not type the requirement by hand; copy it from one of these:

- Every GitHub Release has the exact string as the asset `designated-requirement.txt`. The release pipeline fails if it differs from the previous release's (QA-R30), so a profile written once keeps working across updates (PLT-R752).
- An installed copy: `codesign --display -r - "/Applications/{{AppName}}.app"` prints it on the line that starts with `designated =>`. That output adds `/* exists */` comments and quotes the Team ID; the requirement is the same.

The bundle ID and Team ID never change (PLT-R750). If either ever had to change, the release notes would say so and the profile would need the new requirement.

## 3. macOS 27: Accessibility management moved to Declarative Device Management

- On macOS 27, Accessibility management moved to Declarative Device Management (DDM). Apple's deployment guide states that granting Accessibility through the PPPC payload was deprecated in macOS 26.2 and is removed in macOS 27, and that the replacement is the `Privacy` key of the App Settings declaration, `com.apple.configuration.app.settings`. Apple's "What's new for enterprise" note for macOS 27 still describes the deprecated PPPC key being applied, with a one-time notification to the user per app. VERIFY which applies to the macOS 27 release you deploy, and take the exact declaration keys from Apple's App Settings reference.
- In System Settings, the permission appears under Privacy & Security > **Device Control and Data Access** (the pane called Accessibility on macOS 15 and 26), which groups the managed Accessibility and `PostEvent` grants. VERIFY the label on the macOS 27 version you deploy.
- Keep `PostEvent` and `ListenEvent` in the PPPC payload; at the time of writing, App Settings does not cover them (VERIFY).
- On macOS 27 the user can switch off an Accessibility grant made by device management. The app then shows its permission guidance and passes keys through unchanged until the grant returns (PLT-R730, PLT-R731).

## 4. Example profile (macOS 15 and 26)

Replace `{{app-slug}}`, `TEAM_ID`, the payload identifiers and both UUIDs before use (`uuidgen` prints a new UUID). On macOS 27, move the `Accessibility` entry to the App Settings declaration as described in section 3.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadIdentifier</key>
            <string>org.example.inputmethod.pppc</string>
            <key>PayloadUUID</key>
            <string>REPLACE-WITH-A-NEW-UUID-1</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>Services</key>
            <dict>
                <key>Accessibility</key>
                <array>
                    <dict>
                        <key>Identifier</key>
                        <string>vn.kal.{{app-slug}}</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                        <key>CodeRequirement</key>
                        <string>identifier "vn.kal.{{app-slug}}" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = TEAM_ID</string>
                        <key>Authorization</key>
                        <string>Allow</string>
                    </dict>
                </array>
                <key>PostEvent</key>
                <array>
                    <dict>
                        <key>Identifier</key>
                        <string>vn.kal.{{app-slug}}</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                        <key>CodeRequirement</key>
                        <string>identifier "vn.kal.{{app-slug}}" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = TEAM_ID</string>
                        <key>Authorization</key>
                        <string>Allow</string>
                    </dict>
                </array>
                <key>ListenEvent</key>
                <array>
                    <dict>
                        <key>Identifier</key>
                        <string>vn.kal.{{app-slug}}</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                        <key>CodeRequirement</key>
                        <string>identifier "vn.kal.{{app-slug}}" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = TEAM_ID</string>
                        <key>Authorization</key>
                        <string>AllowStandardUserToSetSystemService</string>
                    </dict>
                </array>
            </dict>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>Input method permissions</string>
    <key>PayloadIdentifier</key>
    <string>org.example.inputmethod</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>REPLACE-WITH-A-NEW-UUID-2</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
```

## 5. Unmanaged Macs

Without device management, the user grants the permissions once in System Settings; the app's onboarding opens the right pane and explains why (PLT-R711). A profile installed by hand cannot pre-approve them: macOS applies the PPPC payload only through a user-approved MDM enrollment.

## 6. Checking a deployment

- System Settings > Privacy & Security > Accessibility (macOS 15 and 26) or Device Control and Data Access (macOS 27): {{AppName}} is listed, marked as managed by a profile, and switched on.
- The in-app report (About & Support) contains a diagnostics block with `permission.accessibility`, `permission.postEvent`, `permission.inputMonitoring` and `permission.health` ([ADR 0501](../decisions/0501-diagnostics-block-format.md)). `permission.health: ready` means the profile works; `noPermission` or `stale` means a grant is missing or no longer matches the code requirement.
- Never reset all permissions with `sudo tccutil reset Accessibility` and no bundle ID: that clears every app's grant (PLT-R741).
