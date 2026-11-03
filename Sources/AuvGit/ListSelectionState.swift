import SwiftUI

/// Keeps a range selected while a single item drives the existing detail pane.
/// An external navigation change replaces the range; ordinary redraws do not.
struct ListSelectionState<ID: Hashable>: Equatable {
    private(set) var ids: Set<ID> = []
    private(set) var primary: ID?
    private var anchor: ID?
    private var deferringDetail = false
    private var previousDetail: ID?
    private var detailRequest: UUID?

    mutating func synchronizePrimaryForDetails(_ id: ID?) { primary = id }

    func selected(primary external: ID?, orderedIDs: [ID]) -> Set<ID> {
        let available = Set(orderedIDs)
        if external != primary, !(deferringDetail && external == previousDetail) {
            return external.map { available.contains($0) ? [$0] : [] } ?? []
        }
        return ids.intersection(available)
    }

    mutating func synchronize(primary external: ID?, orderedIDs: [ID]) {
        let next = selected(primary: external, orderedIDs: orderedIDs)
        let awaitingDetail = deferringDetail && external == previousDetail
        if external != primary, !awaitingDetail { anchor = external }
        ids = next
        if !awaitingDetail { primary = external; deferringDetail = false; previousDetail = nil; detailRequest = nil }
        if let anchor, !orderedIDs.contains(anchor) { self.anchor = nil }
    }

    @discardableResult
    mutating func select(_ proposed: Set<ID>, orderedIDs: [ID], preferred: ID? = nil) -> ID? {
        let next = proposed.intersection(Set(orderedIDs))
        let added = orderedIDs.filter { next.contains($0) && !ids.contains($0) }
        let above = primary.flatMap { orderedIDs.firstIndex(of: $0) }.map { index in
            added.first.flatMap { orderedIDs.firstIndex(of: $0) }.map { $0 < index } ?? false
        } ?? false
        let candidate = preferred.flatMap { next.contains($0) ? $0 : nil }
            ?? (above ? added.first : added.last)
            ?? primary.flatMap { next.contains($0) ? $0 : nil }
            ?? orderedIDs.first(where: next.contains)
        ids = next; primary = candidate
        if next.count == 1 { anchor = candidate }
        return candidate
    }

    mutating func click(_ id: ID, shift: Bool, command: Bool, orderedIDs: [ID]) {
        guard let index = orderedIDs.firstIndex(of: id) else { return }
        if shift, let anchor = anchor ?? primary, let start = orderedIDs.firstIndex(of: anchor) {
            let range = Set(orderedIDs[min(start, index)...max(start, index)])
            select(command ? ids.union(range) : range, orderedIDs: orderedIDs, preferred: id)
        } else if command {
            var next = ids
            if !next.insert(id).inserted { next.remove(id) }
            select(next, orderedIDs: orderedIDs, preferred: id)
            anchor = id
        } else {
            select([id], orderedIDs: orderedIDs, preferred: id)
            anchor = id
        }
    }

    static func binding(_ state: Binding<Self>, primary: Binding<ID?>, orderedIDs: [ID]) -> Binding<Set<ID>> {
        Binding(get: { state.wrappedValue.selected(primary: primary.wrappedValue, orderedIDs: orderedIDs) }, set: { ids in
            var value = state.wrappedValue
            let external = primary.wrappedValue
            value.synchronize(primary: external, orderedIDs: orderedIDs)
            let selected = value.select(ids, orderedIDs: orderedIDs)
            let request = UUID()
            if selected != external { value.deferringDetail = true; value.previousDetail = external; value.detailRequest = request }
            if state.wrappedValue != value { state.wrappedValue = value }
            guard selected != external else { return }
            // SwiftUI can call a List's selection setter while reconciling rows.
            // Publish detail changes after that update, keeping the range intact
            // until the detail catches up and rejecting superseded selections.
            DispatchQueue.main.async {
                guard state.wrappedValue.detailRequest == request else { return }
                if primary.wrappedValue == external { primary.wrappedValue = selected }
                var current = state.wrappedValue
                current.synchronize(primary: primary.wrappedValue, orderedIDs: orderedIDs)
                if state.wrappedValue != current { state.wrappedValue = current }
            }
        })
    }
}
