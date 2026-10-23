/// CursorJumpManager.swift

import Cocoa
import Carbon.HIToolbox
import MASShortcut

/// Moves the cursor between displays. Shortcuts jump it to the center of the
/// adjacent display, a pie menu at the cursor offers the same jumps, and the
/// cursor can optionally wrap from the outermost left/right edge of the
/// desktop to the opposite one.
class CursorJumpManager {

    static let jumpLeftDefaultsKey = "cursorJumpLeft"
    static let jumpRightDefaultsKey = "cursorJumpRight"
    static let jumpUpDefaultsKey = "cursorJumpUp"
    static let jumpDownDefaultsKey = "cursorJumpDown"
    static let pieMenuDefaultsKey = "cursorPieMenu"
    static let defaultsKeys = [jumpLeftDefaultsKey, jumpRightDefaultsKey, jumpUpDefaultsKey, jumpDownDefaultsKey, pieMenuDefaultsKey]

    /// Hyper (⌃⌥⇧⌘) is used by neither the Spectacle nor the recommended
    /// default set, so these don't take a window action's keys.
    private static let defaultModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private static var shortcutBindingsSessionActive = true
    private static var shortcutBindingsSuspended = false
    private static weak var instance: CursorJumpManager?

    private let edgeWrapper = CursorEdgeWrapper()
    private let pieMenu = CursorPieMenu()

    init() {
        Self.instance = self
        pieMenu.onOpenChange = { [weak self] open in self?.edgeWrapper.isSuspended = open }

        MASShortcutBinder.shared()?.registerDefaultShortcuts(Self.defaultShortcuts())

        NotificationCenter.default.addObserver(
            forName: .cursorJumpChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyEdgeWrapSettings()
        }
        NotificationCenter.default.addObserver(
            forName: .configImported,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reevaluateShortcuts()
            self?.applyEdgeWrapSettings()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.pieMenu.close()
        }

        registerUnregisterShortcuts()
        applyEdgeWrapSettings()
    }

    static func displayName(forDefaultsKey defaultsKey: String) -> String? {
        switch defaultsKey {
        case jumpLeftDefaultsKey: return String(localized: "Move cursor to left display")
        case jumpRightDefaultsKey: return String(localized: "Move cursor to right display")
        case jumpUpDefaultsKey: return String(localized: "Move cursor to display above")
        case jumpDownDefaultsKey: return String(localized: "Move cursor to display below")
        case pieMenuDefaultsKey: return String(localized: "Show display pie menu")
        default: return nil
        }
    }

    static func defaultShortcuts() -> [String: MASShortcut] {
        [
            jumpLeftDefaultsKey: MASShortcut(keyCode: kVK_LeftArrow, modifierFlags: defaultModifiers),
            jumpRightDefaultsKey: MASShortcut(keyCode: kVK_RightArrow, modifierFlags: defaultModifiers),
            jumpUpDefaultsKey: MASShortcut(keyCode: kVK_UpArrow, modifierFlags: defaultModifiers),
            jumpDownDefaultsKey: MASShortcut(keyCode: kVK_DownArrow, modifierFlags: defaultModifiers),
            pieMenuDefaultsKey: MASShortcut(keyCode: kVK_Space, modifierFlags: defaultModifiers)
        ]
    }

    private func action(forDefaultsKey defaultsKey: String) -> () -> Void {
        switch defaultsKey {
        case Self.jumpLeftDefaultsKey: return { [weak self] in self?.jump(.left) }
        case Self.jumpRightDefaultsKey: return { [weak self] in self?.jump(.right) }
        case Self.jumpUpDefaultsKey: return { [weak self] in self?.jump(.up) }
        case Self.jumpDownDefaultsKey: return { [weak self] in self?.jump(.down) }
        default: return { [weak self] in self?.pieMenu.toggle() }
        }
    }

    private func jump(_ direction: CursorDirection) {
        pieMenu.close()
        let displays = CursorDisplays.all()
        guard let source = CursorDisplays.display(at: CursorDisplays.cursorLocation, in: displays),
              let target = CursorDisplays.neighbor(of: source, direction, in: displays)
        else { return }
        CursorDisplays.warp(to: target.center)
    }

    private func applyEdgeWrapSettings() {
        edgeWrapper.wrapsWhileDragging = Defaults.cursorEdgeWrapWhileDragging.userEnabled
        edgeWrapper.requiresMultipleDisplays = !Defaults.cursorEdgeWrapMultipleDisplaysOnly.userDisabled
        if Defaults.cursorEdgeWrap.userEnabled {
            edgeWrapper.start()
        } else {
            edgeWrapper.stop()
        }
    }

    // MARK: - Shortcut bindings

    private func registerShortcuts() {
        for defaultsKey in Self.defaultsKeys {
            guard Self.isShortcutBindable(defaultsKey) else {
                MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: defaultsKey)
                continue
            }
            MASShortcutBinder.shared()?.bindShortcut(withDefaultsKey: defaultsKey, toAction: action(forDefaultsKey: defaultsKey))
        }
    }

    private func unregisterShortcuts() {
        for defaultsKey in Self.defaultsKeys {
            MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: defaultsKey)
        }
    }

    private func registerUnregisterShortcuts() {
        if Self.shortcutBindingsSessionActive && !Self.shortcutBindingsSuspended {
            registerShortcuts()
        } else {
            unregisterShortcuts()
            pieMenu.close()
        }
    }

    /// Break the bindings first so re-evaluation can't stack a second action
    /// on the same defaults key.
    private func reevaluateShortcuts() {
        unregisterShortcuts()
        registerUnregisterShortcuts()
    }

    static func setShortcutBindingsSessionActive(_ isActive: Bool) {
        guard shortcutBindingsSessionActive != isActive else { return }
        shortcutBindingsSessionActive = isActive
        instance?.reevaluateShortcuts()
    }

    static func setShortcutBindingsSuspended(_ suspended: Bool) {
        guard shortcutBindingsSuspended != suspended else { return }
        shortcutBindingsSuspended = suspended
        instance?.reevaluateShortcuts()
    }

    private static func isShortcutBindable(_ defaultsKey: String) -> Bool {
        guard let shortcut = ShortcutCycle.shortcut(forDefaultsKey: defaultsKey) else { return true }
        return AppShortcutConflict.conflict(for: shortcut, ignoringDefaultsKey: defaultsKey) == nil
    }
}
