// NotificationKeys — keyboard navigation for macOS notifications.
//
// Global hotkeys (Carbon, no permission needed):
//   ⌃⌥N   toggle navigation mode (opens Notification Center if needed)
//   ⌃⌥⇧N  clear all notifications without entering navigation mode
//
// Navigation mode (CGEventTap, needs Accessibility permission):
//   ↑ / ↓ (or k / j)      move selection
//   Return                perform the default action of the selected notification
//   Space / →             expand a stack or show details
//   Delete / x            close the selected notification (or clear its stack)
//   ⇧Delete / ⌘Delete / a clear all notifications
//   Esc                   leave navigation mode and close Notification Center

import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import os
import ServiceManagement

let log = Logger(subsystem: "local.notificationkeys", category: "main")

// MARK: - Accessibility helpers

let ncBundleID = "com.apple.notificationcenterui"
let controlCenterBundleID = "com.apple.controlcenter"

func axAttr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    axAttr(e, kAXChildrenAttribute) ?? []
}

/// Raw action names, e.g. "AXPress" or "Name:Close\nTarget:0x0\nSelector:(null)".
func axActions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
    return names as? [String] ?? []
}

/// Short action name: "Name:Close\n…" becomes "Close".
func shortName(_ action: String) -> String {
    guard action.hasPrefix("Name:") else { return action }
    let firstLine = action.split(separator: "\n").first.map(String.init) ?? action
    return String(firstLine.dropFirst("Name:".count))
}

@discardableResult
func axPerform(_ e: AXUIElement, matching names: [String]) -> Bool {
    for action in axActions(e) where names.contains(shortName(action)) {
        if AXUIElementPerformAction(e, action as CFString) == .success { return true }
    }
    return false
}

func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let posValue: AXValue = axAttr(e, kAXPositionAttribute),
          let sizeValue: AXValue = axAttr(e, kAXSizeAttribute) else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(posValue, .cgPoint, &pos)
    AXValueGetValue(sizeValue, .cgSize, &size)
    return CGRect(origin: pos, size: size)
}

// MARK: - Notification Center access

enum NotificationCenterUI {
    static var appElement: AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ncBundleID).first else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    static func isNotification(_ e: AXUIElement) -> Bool {
        let subrole: String = axAttr(e, kAXSubroleAttribute) ?? ""
        if subrole.hasPrefix("AXNotificationCenter") && !subrole.contains("Widget") { return true }
        return axActions(e).map(shortName).contains { $0 == "Close" || $0 == "Clear All" }
    }

    /// True when the Notification Center panel (an AXSystemDialog window) is on screen.
    static var isOpen: Bool {
        guard let app = appElement else { return false }
        return axChildren(app).contains { e in
            (axAttr(e, kAXRoleAttribute) as String?) == kAXWindowRole
                && (axAttr(e, kAXSubroleAttribute) as String?) == "AXSystemDialog"
        }
    }

    /// Clears all notifications, then closes Notification Center if it is open.
    static func clearAllAndClose() {
        clearAll()
        if isOpen { toggle() }
    }

    static func isStack(_ e: AXUIElement) -> Bool {
        let subrole: String = axAttr(e, kAXSubroleAttribute) ?? ""
        return subrole.contains("Stack")
    }

    /// Notifications and notification stacks, top to bottom.
    static func notifications() -> [AXUIElement] {
        guard let app = appElement else { return [] }
        var found: [AXUIElement] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 20 else { return }
            for child in axChildren(e) {
                let match = isNotification(child)
                if match { found.append(child) }
                if !match || isStack(child) { walk(child, depth: depth + 1) }
            }
        }
        walk(app, depth: 0)
        return found
            .compactMap { e in axFrame(e).map { (e, $0) } }
            .filter { $0.1.width > 1 && $0.1.height > 1 }
            .sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
            .map { $0.0 }
    }

    /// Toggles Notification Center by pressing the clock menu extra.
    /// macOS 27 hosts menu extras in MenuBarAgent, nested in AXGroup elements; earlier releases use Control Center.
    @discardableResult
    static func toggle() -> Bool {
        func findClock(_ e: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 4 else { return nil }
            for child in axChildren(e) {
                let identifier: String = axAttr(child, kAXIdentifierAttribute) ?? ""
                if identifier == "com.apple.menuextra.clock" { return child }
                if let found = findClock(child, depth: depth + 1) { return found }
            }
            return nil
        }
        for bundleID in ["com.apple.MenuBarAgent", controlCenterBundleID] {
            guard let host = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  let bar: AXUIElement = axAttr(AXUIElementCreateApplication(host.processIdentifier), "AXExtrasMenuBar"),
                  let clock = findClock(bar, depth: 0) else { continue }
            let result = AXUIElementPerformAction(clock, kAXPressAction as CFString)
            log.notice("clock press via \(bundleID, privacy: .public) result \(result.rawValue, privacy: .public)")
            return result == .success
        }
        log.notice("clock menu extra not found")
        return false
    }

    /// Closes every notification and stack. Repeats because closing one element rebuilds the tree.
    static func clearAll() {
        for _ in 0..<50 {
            let items = notifications()
            guard !items.isEmpty else { return }
            var progressed = false
            for item in items where axPerform(item, matching: ["Clear All", "Close"]) {
                progressed = true
            }
            guard progressed else { return }
            usleep(150_000)
        }
    }
}

// MARK: - Selection overlay

final class HighlightWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 3
        view.layer?.cornerRadius = 16
        contentView = view
    }

    /// `axRect` uses AX coordinates: origin at the top-left of the primary screen.
    func show(axRect: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: axRect.minX, y: primaryHeight - axRect.maxY, width: axRect.width, height: axRect.height)
        setFrame(rect.insetBy(dx: -3, dy: -3), display: true)
        orderFrontRegardless()
    }
}

// MARK: - Navigation mode

final class Navigator {
    static let shared = Navigator()

    private(set) var active = false
    private var index = 0
    private var openedNotificationCenter = false
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let highlight = HighlightWindow()

    func toggle() { active ? stop(closeCenter: true) : start() }

    func start() {
        log.notice("start: trusted=\(AXIsProcessTrusted(), privacy: .public)")
        guard ensureTrusted() else { return }
        active = true
        index = 0
        openedNotificationCenter = false
        installEventTap()
        if NotificationCenterUI.notifications().isEmpty {
            openedNotificationCenter = NotificationCenterUI.toggle()
            waitForNotifications(attempts: 8)
        } else {
            refresh()
        }
    }

    func stop(closeCenter: Bool) {
        active = false
        highlight.orderOut(nil)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            eventTap = nil
            tapSource = nil
        }
        if closeCenter && openedNotificationCenter { NotificationCenterUI.toggle() }
        openedNotificationCenter = false
    }

    /// Notification Center needs a moment to build its window after the clock press; poll every 0.25 s.
    private func waitForNotifications(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.active else { return }
            if attempts > 1 && NotificationCenterUI.notifications().isEmpty {
                self.waitForNotifications(attempts: attempts - 1)
            } else {
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard active else { return }
        let items = NotificationCenterUI.notifications()
        log.notice("refresh: \(items.count, privacy: .public) notifications, index \(self.index, privacy: .public)")
        guard !items.isEmpty else {
            highlight.orderOut(nil)
            NSSound.beep()
            return
        }
        index = min(max(index, 0), items.count - 1)
        let selected = items[index]
        axPerform(selected, matching: ["AXScrollToVisible"])
        if let frame = axFrame(selected) { highlight.show(axRect: frame) }
    }

    private func current() -> AXUIElement? {
        let items = NotificationCenterUI.notifications()
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
    }

    /// Returns true when the key was handled and must not reach other apps.
    func handle(keyCode: Int, flags: CGEventFlags) -> Bool {
        let shift = flags.contains(.maskShift), command = flags.contains(.maskCommand)
        switch keyCode {
        case kVK_DownArrow, kVK_ANSI_J:
            index += 1; refresh()
        case kVK_UpArrow, kVK_ANSI_K:
            index -= 1; refresh()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let e = current() {
                axPerform(e, matching: [kAXPressAction])
                stop(closeCenter: false)
            }
        case kVK_Space, kVK_RightArrow:
            if let e = current() {
                axPerform(e, matching: NotificationCenterUI.isStack(e) ? [kAXPressAction] : ["Show Details", kAXPressAction])
                refreshSoon()
            }
        case kVK_Delete, kVK_ForwardDelete, kVK_ANSI_X:
            if shift || command {
                stop(closeCenter: false)
                NotificationCenterUI.clearAllAndClose()
            } else if let e = current() {
                axPerform(e, matching: ["Close", "Clear All"])
                refreshSoon()
            }
        case kVK_ANSI_A:
            stop(closeCenter: false)
            NotificationCenterUI.clearAllAndClose()
        case kVK_Escape:
            stop(closeCenter: true)
        default:
            return false
        }
        return true
    }

    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let navigator = Navigator.shared
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = navigator.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard navigator.active, type == .keyDown else { return Unmanaged.passUnretained(event) }
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            // Leave other shortcuts (⌃, ⌥, and ⌘ with anything but Delete) to the system.
            if flags.contains(.maskControl) || flags.contains(.maskAlternate) { return Unmanaged.passUnretained(event) }
            if flags.contains(.maskCommand) && keyCode != kVK_Delete { return Unmanaged.passUnretained(event) }
            return navigator.handle(keyCode: keyCode, flags: flags) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            log.error("could not create event tap; check Accessibility permission")
            active = false
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func ensureTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return true }
        log.notice("not trusted; opening Accessibility settings")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        return false
    }
}

// MARK: - Global hotkeys

enum HotKeyID: UInt32 { case navigate = 1, clearAll = 2 }

func registerHotKeys() {
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        log.notice("hotkey \(hotKeyID.id, privacy: .public)")
        switch HotKeyID(rawValue: hotKeyID.id) {
        case .navigate: Navigator.shared.toggle()
        case .clearAll:
            Navigator.shared.stop(closeCenter: false)
            NotificationCenterUI.clearAllAndClose()
        case nil: break
        }
        return noErr
    }, 1, &eventType, nil, nil)

    let signature = OSType(0x4E4B4559) // "NKEY"
    var ref: EventHotKeyRef?
    let navigateStatus = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey),
                        EventHotKeyID(signature: signature, id: HotKeyID.navigate.rawValue), GetApplicationEventTarget(), 0, &ref)
    let clearStatus = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | shiftKey),
                        EventHotKeyID(signature: signature, id: HotKeyID.clearAll.rawValue), GetApplicationEventTarget(), 0, &ref)
    log.notice("hotkey registration: navigate=\(navigateStatus, privacy: .public) clearAll=\(clearStatus, privacy: .public)")
}

// MARK: - Structure dump

/// Writes the accessibility structure of Notification Center and the Control Center menu extras to `path`.
/// Only roles, subroles, identifiers, and action names are written; no titles, values, or notification text.
func dumpStructure(to path: String) {
    var lines = ["trusted: \(AXIsProcessTrusted())"]
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard depth < 25 else { return }
        let role: String = axAttr(e, kAXRoleAttribute) ?? "?"
        let subrole: String = axAttr(e, kAXSubroleAttribute) ?? ""
        let identifier: String = axAttr(e, kAXIdentifierAttribute) ?? ""
        let actions = axActions(e).map(shortName).joined(separator: ",")
        let frame = axFrame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
        lines.append(String(repeating: "  ", count: depth) + "\(role) sub=\(subrole) id=\(identifier) actions=[\(actions)] frame=\(frame)")
        for child in axChildren(e) { walk(child, depth + 1) }
    }
    lines.append("== \(ncBundleID)")
    if let nc = NotificationCenterUI.appElement { walk(nc, 0) } else { lines.append("not running") }
    // Menu bar extras: list top-level menu bars of the processes that can host them.
    // AXDescription is included here only; it holds the menu extra's name, not notification text.
    for running in NSWorkspace.shared.runningApplications {
        let name = running.executableURL?.lastPathComponent ?? ""
        guard ["ControlCenter", "SystemUIServer", "MenuBarAgent"].contains(name) else { continue }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        lines.append("== \(name) pid=\(running.processIdentifier) bundle=\(running.bundleIdentifier ?? "")")
        for attribute in ["AXExtrasMenuBar", kAXMenuBarAttribute] {
            guard let bar: AXUIElement = axAttr(element, attribute) else { lines.append("  \(attribute): none"); continue }
            lines.append("  \(attribute):")
            func walkExtras(_ e: AXUIElement, _ depth: Int) {
                guard depth < 5 else { return }
                for item in axChildren(e) {
                    let role: String = axAttr(item, kAXRoleAttribute) ?? "?"
                    let subrole: String = axAttr(item, kAXSubroleAttribute) ?? ""
                    let identifier: String = axAttr(item, kAXIdentifierAttribute) ?? ""
                    let description: String = axAttr(item, kAXDescriptionAttribute) ?? ""
                    let frame = axFrame(item).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
                    lines.append(String(repeating: "  ", count: depth + 2) + "\(role) sub=\(subrole) id=\(identifier) desc=\(description) actions=[\(axActions(item).map(shortName).joined(separator: ","))] frame=\(frame)")
                    walkExtras(item, depth + 1)
                }
            }
            walkExtras(bar, 0)
        }
        lines.append("  windows=\(axChildren(element).count) top-level children")
    }
    lines.append("== matched notifications: \(NotificationCenterUI.notifications().count)")
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHotKeys()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "NotificationKeys")
        let menu = NSMenu()
        menu.addItem(withTitle: "Navigate Notifications (⌃⌥N)", action: #selector(navigate), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear All Notifications (⌃⌥⇧N)", action: #selector(clearAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotificationKeys", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        // Register as a login item on first launch; afterwards the menu item controls it.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            setLoginItem(enabled: true)
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    @objc func toggleLoginItem(_ sender: NSMenuItem) {
        setLoginItem(enabled: SMAppService.mainApp.status != .enabled)
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        log.notice("login item status \(SMAppService.mainApp.status.rawValue, privacy: .public)")
    }

    @objc func navigate() { Navigator.shared.start() }
    @objc func clearAll() {
        Navigator.shared.stop(closeCenter: false)
        NotificationCenterUI.clearAllAndClose()
    }
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--dump"), arguments.indices.contains(flag + 1) {
    if let delay = arguments.firstIndex(of: "--delay").flatMap({ arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil }) {
        Thread.sleep(forTimeInterval: delay)
    }
    let openCenter = arguments.contains("--open")
    if openCenter { NotificationCenterUI.toggle(); Thread.sleep(forTimeInterval: 1.0) }
    dumpStructure(to: arguments[flag + 1])
    if openCenter { NotificationCenterUI.toggle() }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
