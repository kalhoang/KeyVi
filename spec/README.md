# Specification: {{AppName}}, a Vietnamese input method for macOS

Start with [00-overview.md](00-overview.md). Implementers must read [05-clean-room.md](05-clean-room.md) before writing any code.

| File | Contents |
|---|---|
| [00-overview.md](00-overview.md) | Decisions made, reading order, name, open decisions, first steps |
| [03-product.md](03-product.md) | Product: P0 list, principles, scope, defaults, UI, onboarding, website |
| [01-engine.md](01-engine.md) | Typing engine: orthography, Telex/VNI, tone placement, restore, API, tests |
| [02-platform.md](02-platform.md) | macOS host: event tap, injection, compatibility rules, permissions, privacy, updates |
| [04-quality-release.md](04-quality-release.md) | Testing, CI, release, issue policy, support |
| [05-clean-room.md](05-clean-room.md) | Clean-room rules and provenance |
| [reference-model/](reference-model/) | Python test oracle for engine test data (not shipped) |

Placeholders: `{{AppName}}` (display name) and `{{app-slug}}` (ASCII slug). See 00-overview.md section 4.
