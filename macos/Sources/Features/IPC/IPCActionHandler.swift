import Foundation
import AppKit
import GhosttyKit

/// Unified action dispatcher for IPC operations.
/// Used by the socket server for IPC operations.
@MainActor
final class IPCActionHandler {
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    private var ghostty: Ghostty.App? {
        appDelegate?.ghostty
    }

    // MARK: - Terminal Discovery

    func listTerminals() -> [TerminalInfo] {
        return TerminalRegistry.allTerminals()
    }

    func findTerminal(id: String) -> Ghostty.SurfaceView? {
        return TerminalRegistry.find(idString: id)
    }

    func focusedTerminal() -> Ghostty.SurfaceView? {
        return TerminalRegistry.focused()
    }

    // MARK: - Terminal Creation

    func newWindow(command: String? = nil, directory: String? = nil) -> String? {
        guard let ghostty else { return nil }

        var config = Ghostty.SurfaceConfiguration()
        if let command {
            config.initialInput = "\(command); exit\n"
        }
        if let directory {
            config.workingDirectory = directory
        }

        let controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        if let view = controller.surfaceTree.root?.leftmostLeaf() {
            return view.id.uuidString
        }
        return nil
    }

    func newTab(windowId: String? = nil, command: String? = nil, directory: String? = nil) -> String? {
        guard let ghostty else { return nil }

        var config = Ghostty.SurfaceConfiguration()
        if let command {
            config.initialInput = "\(command); exit\n"
        }
        if let directory {
            config.workingDirectory = directory
        }

        // Find the target window
        let targetWindow: NSWindow?
        if let windowId, let windowNumber = Int(windowId) {
            targetWindow = NSApp.windows.first { $0.windowNumber == windowNumber }
        } else {
            targetWindow = TerminalController.preferredParent?.window
        }

        if let controller = TerminalController.newTab(ghostty, from: targetWindow, withBaseConfig: config) {
            if let view = controller.surfaceTree.root?.leftmostLeaf() {
                return view.id.uuidString
            }
        }
        return nil
    }

    func newSplit(terminalId: String, direction: String) -> String? {
        guard let surface = TerminalRegistry.find(idString: terminalId),
              let controller = surface.window?.windowController as? BaseTerminalController else {
            return nil
        }

        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch direction.lowercased() {
        case "left": splitDirection = .left
        case "right": splitDirection = .right
        case "up": splitDirection = .up
        case "down": splitDirection = .down
        default: return nil
        }

        if let newView = controller.newSplit(at: surface, direction: splitDirection, baseConfig: nil) {
            return newView.id.uuidString
        }
        return nil
    }

    // MARK: - Terminal Operations

    func closeTerminal(id: String) -> Bool {
        guard let surface = TerminalRegistry.find(idString: id),
              let surfaceModel = surface.surfaceModel else {
            return false
        }
        // Use the close_surface action to properly close the terminal
        return surfaceModel.perform(action: "close_surface")
    }

    func focusTerminal(id: String) -> Bool {
        guard let surface = TerminalRegistry.find(idString: id),
              let window = surface.window else {
            return false
        }

        // Bring window to front
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Focus the specific surface within the window
        if let controller = window.windowController as? BaseTerminalController {
            controller.focusSurface(surface)
        }

        return true
    }

    func sendText(terminalId: String, text: String) -> Bool {
        guard let surface = TerminalRegistry.find(idString: terminalId),
              let surfaceModel = surface.surfaceModel else {
            return false
        }
        surfaceModel.sendText(text)
        return true
    }

    // MARK: - Actions

    func performAction(terminalId: String?, action: String) -> Bool {
        // Find the target surface - either specified or focused
        let surface: Ghostty.SurfaceView?
        if let terminalId {
            surface = TerminalRegistry.find(idString: terminalId)
        } else {
            surface = TerminalRegistry.focused()
        }

        guard let surface, let surfaceObj = surface.surface else {
            return false
        }

        return ghostty_surface_binding_action(
            surfaceObj,
            action,
            UInt(action.lengthOfBytes(using: .utf8))
        )
    }

    // MARK: - App Operations

    func reloadConfig() -> Bool {
        ghostty?.reloadConfig()
        return true
    }

    func toggleQuickTerminal() -> Bool {
        appDelegate?.quickController.toggle()
        return true
    }

    func toggleVisibility() -> Bool {
        appDelegate?.toggleVisibility(self)
        return true
    }

    // MARK: - Screen Content

    func writeScreenFile(surfaceId: String) -> String? {
        guard let surfaceView = TerminalRegistry.find(idString: surfaceId),
              let surface = surfaceView.surface else {
            return nil
        }

        // Create selection for full scrollback + screen
        // TL: GHOSTTY_POINT_SURFACE (history) + TOP_LEFT = start of scrollback
        // BR: GHOSTTY_POINT_SCREEN + BOTTOM_RIGHT = end of visible screen
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SURFACE,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        // Convert to Swift string
        guard let textPtr = text.text else { return nil }
        let content = String(cString: textPtr)

        // Write to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "ghostty-screen-\(UUID().uuidString).txt"
        let filePath = tempDir.appendingPathComponent(filename)

        do {
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            return filePath.path
        } catch {
            return nil
        }
    }
}
