import AppKit
import Combine

final class ComparisonEditingCommands: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var searchCurrent = 0
    @Published private(set) var searchTotal = 0
    var focusEditorAction: (() -> Void)?
    var selectReadOnlyRangeAction: ((String, NSRange) -> Void)?
    func revealRange(paneID: String, range: NSRange) { selectReadOnlyRangeAction?(paneID, range) }
    var revealLineAction: ((String, Int) -> Void)?
    func focusEditor() { focusEditorAction?() }
    func revealLine(paneID: String, number: Int) { revealLineAction?(paneID, number) }
    func updateSearch(current: Int, total: Int) {
        if searchCurrent != current { searchCurrent = current }
        if searchTotal != total { searchTotal = total }
    }
    private var undoAction: (() -> Void)?
    private var redoAction: (() -> Void)?
    var replaceSearchAction: ((ComparisonSearchOptions, String, Bool) -> String?)?
    func replaceSearch(options: ComparisonSearchOptions, replacement: String, all: Bool) -> String? {
        replaceSearchAction?(options, replacement, all)
    }
    func undo() { guard canUndo else { return }; undoAction?() }
    func redo() { guard canRedo else { return }; redoAction?() }
    func connect(undo: @escaping () -> Void, redo: @escaping () -> Void) { undoAction = undo; redoAction = redo }
    func update(canUndo: Bool, canRedo: Bool) {
        if self.canUndo != canUndo { self.canUndo = canUndo }
        if self.canRedo != canRedo { self.canRedo = canRedo }
    }
}

/// NSTextView registers its normal editing operations in this pane-owned manager.
/// Explicit groups keep toolbar replacements separate from surrounding typing.
class UndoableComparisonTextView: NSTextView {
    private let history = UndoManager()
    private var ownsTypingGroup = false
    private var ownedStorage: NSTextStorage?
    var historyChanged: (() -> Void)?
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container { super.init(frame: frameRect, textContainer: container) }
        else {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: max(1, frameRect.width), height: .greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            super.init(frame: frameRect, textContainer: container)
            ownedStorage = storage
        }
        history.groupsByEvent = false
        allowsUndo = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        history.groupsByEvent = false
        allowsUndo = true
    }
    var editingUndoManager: UndoManager { history }
    override var undoManager: UndoManager? { history }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if history.groupingLevel == 0, !history.isUndoing, !history.isRedoing {
            history.beginUndoGrouping()
            ownsTypingGroup = true
        }
        let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if !accepted, ownsTypingGroup { ownsTypingGroup = false; history.endUndoGrouping() }
        return accepted
    }
    override func didChangeText() {
        if ownsTypingGroup { ownsTypingGroup = false; history.endUndoGrouping() }
        super.didChangeText()
        historyChanged?()
    }
    func replaceAsUndoableEdit(_ value: String, range: NSRange? = nil, actionName: String? = nil) {
        let replacement = range ?? NSRange(location: 0, length: string.utf16.count)
        guard (string as NSString).substring(with: replacement) != value else { return }
        breakUndoCoalescing()
        history.beginUndoGrouping()
        let wasEditable = isEditable
        isEditable = true
        insertText(value, replacementRange: replacement)
        isEditable = wasEditable
        // With groupsByEvent disabled, AppKit requires the operation group to
        // remain open while assigning its name (including Replace All).
        if let actionName { history.setActionName(actionName) }
        history.endUndoGrouping()
        breakUndoCoalescing()
        historyChanged?()
    }
}
