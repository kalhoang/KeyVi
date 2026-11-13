// SPDX-License-Identifier: GPL-3.0-or-later
//
// NSPasteboard access behind `NSPasteboardAccess` (PLT-R461). Tests use a uniquely named pasteboard, which
// macOS always allows without an access alert; the general pasteboard is touched only by the app.

internal import AppKit
internal import Foundation
internal import RealtimeSupport
internal import UniformTypeIdentifiers

/// VERIFY (PLT-R462): AppKit does not document `NSPasteboard` as thread-safe. It is used by one thread at a time:
/// the `inject` thread, or the bounded-read queue while the `inject` thread waits for it. A snapshot that
/// overran its deadline keeps the read queue busy; until it ends the other calls do not touch the pasteboard
/// (`changeCount` answers `unknownChangeCount`, writes fail). That discipline is the reason for `@unchecked`.
final class PasteboardIO: @unchecked Sendable {
    /// Never a real change count: comparisons with a recorded one fail, so nothing is restored over it.
    static let unknownChangeCount = Int.min

    private let pasteboard: NSPasteboard
    private let clock = MachClock()
    private let reads = BoundedRead(label: "pasteboard-read")

    init(name: String?) {
        pasteboard = name.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
    }

    var changeCount: Int { reads.isBusy ? Self.unknownChangeCount : pasteboard.changeCount }

    /// Step 1, bounded: a lazily provided type makes `data(forType:)` wait on its owner, which may be slow or
    /// hung, and a single read cannot be interrupted. The read runs on the bounded-read queue and the snapshot
    /// gives up after `readTimeout` (PLT-R461 step 1, PLT-R462): the paste is abandoned and the fallback types.
    func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot {
        let read = reads.run(timeout: limits.readTimeout) { [self] () -> Result<PasteboardSnapshot, PasteboardError> in
            do throws(PasteboardError) {
                return .success(try readSnapshot(limits: limits))
            } catch {
                return .failure(error)
            }
        }
        guard let read else { throw .timedOut }
        return try read.get()
    }

    /// Every item with every readable type. Aborts on file promises, data that cannot be materialised, more than
    /// `maxTotalBytes`, more than `readTimeout` in total (also checked between reads), or a change by another
    /// app while reading.
    private func readSnapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot {
        let started = clock.now()
        let timeout = InjectionTiming.nanoseconds(limits.readTimeout)
        let changeCount = pasteboard.changeCount
        guard let items = pasteboard.pasteboardItems else { throw .unreadableItem }
        var snapshotItems: [PasteboardItemData] = []
        var total = 0
        for item in items {
            if item.types.contains(where: { Self.isFilePromise($0.rawValue) }) { throw .filePromise }
            var types: [String] = []
            var missing: [String] = []
            var data: [String: Data] = [:]
            for type in item.types {
                guard let bytes = item.data(forType: type) else {
                    missing.append(type.rawValue)
                    continue
                }
                total += bytes.count
                guard total <= limits.maxTotalBytes else { throw .tooLarge }
                guard clock.now().nanoseconds(since: started) <= timeout else { throw .timedOut }
                types.append(type.rawValue)
                data[type.rawValue] = bytes
            }
            guard missing.allSatisfy({ Self.isRederivable($0, from: types) }) else { throw .lazyDataUnavailable }
            snapshotItems.append(PasteboardItemData(types: types, data: data))
        }
        guard pasteboard.changeCount == changeCount else { throw .unreadableItem }
        return PasteboardSnapshot(changeCount: changeCount, items: snapshotItems, totalBytes: total)
    }

    /// Step 2: one item with plain text and the nspasteboard.org marker types; returns the new `changeCount`.
    func writeTransient(_ text: String) throws(PasteboardError) -> Int {
        guard !reads.isBusy else { throw .writeFailed }  // an overrun read still holds the pasteboard
        let item = NSPasteboardItem()
        guard item.setData(Data(text.utf8), forType: NSPasteboard.PasteboardType(PasteboardTypeName.plainText))
        else { throw .writeFailed }
        for marker in PasteboardTypeName.markers {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw .writeFailed }
        return pasteboard.changeCount
    }

    /// Step 5: all saved items and types, in their original order.
    func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) {
        guard !reads.isBusy else { throw .writeFailed }
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { saved in
            let item = NSPasteboardItem()
            for type in saved.types {
                if let bytes = saved.data[type] { item.setData(bytes, forType: NSPasteboard.PasteboardType(type)) }
            }
            return item
        }
        guard pasteboard.writeObjects(items) else { throw .writeFailed }
    }

    /// File promises cannot be restored once read (the promised file may never be written).
    static let filePromiseTypes: Set<String> = Set(
        [kPasteboardTypeFileURLPromise as String, kPasteboardTypeFilePromiseContent as String]
            + NSFilePromiseReceiver.readableDraggedTypes)

    static func isFilePromise(_ type: String) -> Bool { filePromiseTypes.contains(type) }

    /// A type without data is acceptable only when the pasteboard server derives it again from a type that is
    /// saved: a dynamic (legacy-name) type, or a plain-text conversion while another plain-text type was read.
    /// Anything else is owner-provided data that cannot be materialised: abort (PLT-R461 step 1).
    static func isRederivable(_ type: String, from saved: [String]) -> Bool {
        guard let uti = UTType(type) else { return false }
        if uti.isDynamic { return true }
        return uti.conforms(to: .plainText) && saved.contains { UTType($0)?.conforms(to: .plainText) == true }
    }
}
