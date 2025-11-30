import Foundation
import GhosttyKit

/// Handles method dispatch to IPCActionHandler
@MainActor
final class Handler {
    private let actionHandler: IPCActionHandler

    init(actionHandler: IPCActionHandler) {
        self.actionHandler = actionHandler
    }

    /// Handle a request and return a response as JSONValue
    func handle(request: Request) -> JSONValue {
        let params = request.params ?? [:]

        switch request.method {
        case "ping":
            return ["ok": true]

        case "list_surfaces":
            return handleListSurfaces()

        case "get_surface":
            return handleGetSurface(params: params)

        case "get_focused_surface":
            return handleGetFocusedSurface()

        case "new_window":
            return handleNewWindow(params: params)

        case "new_tab":
            return handleNewTab(params: params)

        case "new_split":
            return handleNewSplit(params: params)

        case "close_surface":
            return handleCloseSurface(params: params)

        case "focus_surface":
            return handleFocusSurface(params: params)

        case "send_text":
            return handleSendText(params: params)

        case "action":
            return handleAction(params: params)

        case "reload_config":
            return handleReloadConfig()

        case "toggle_quick_terminal":
            return handleToggleQuickTerminal()

        case "toggle_visibility":
            return handleToggleVisibility()

        case "write_screen_file":
            return handleWriteScreenFile(params: params)

        default:
            return .object(["error": .string("Method not found: \(request.method)")])
        }
    }

    // MARK: - Method Handlers

    private func handleListSurfaces() -> JSONValue {
        let surfaces = actionHandler.listTerminals()
        let surfaceValues: [JSONValue] = surfaces.map { surface in
            .object([
                "id": .string(surface.id),
                "title": .string(surface.title),
                "pwd": surface.pwd.map { .string($0) } ?? .null,
                "window_id": surface.windowId.map { .string($0) } ?? .null,
                "is_focused": .bool(surface.isFocused),
                "is_quick_terminal": .bool(surface.isQuickTerminal),
                "rows": .int(surface.rows),
                "columns": .int(surface.columns),
                "foreground_process_name": surface.foregroundProcessName.map { .string($0) } ?? .null,
                "foreground_process_pid": surface.foregroundProcessPid.map { .int($0) } ?? .null,
                "neighbors": neighborsToJSON(surface.neighbors)
            ])
        }
        return .array(surfaceValues)
    }

    /// Convert Neighbors to JSON
    private func neighborsToJSON(_ neighbors: Neighbors?) -> JSONValue {
        guard let neighbors else { return .null }
        return .object([
            "left": neighbors.left.map { .string($0) } ?? .null,
            "right": neighbors.right.map { .string($0) } ?? .null,
            "up": neighbors.up.map { .string($0) } ?? .null,
            "down": neighbors.down.map { .string($0) } ?? .null
        ])
    }

    private func handleGetSurface(params: [String: JSONValue]) -> JSONValue {
        guard let surfaceId = params["id"]?.stringValue else {
            return .object(["error": .string("Missing 'id' parameter")])
        }

        guard let surface = actionHandler.findTerminal(id: surfaceId) else {
            return .object(["error": .string("Surface not found")])
        }

        return surfaceToJSON(surface)
    }

    private func handleGetFocusedSurface() -> JSONValue {
        guard let surface = actionHandler.focusedTerminal() else {
            return .null
        }

        return surfaceToJSON(surface)
    }

    /// Convert a surface to a JSON object with all surface info
    private func surfaceToJSON(_ surface: Ghostty.SurfaceView) -> JSONValue {
        let size = surface.surfaceSize
        let windowId = surface.window?.windowNumber.description
        let isQuickTerminal = surface.window?.windowController is QuickTerminalController
        let isFocused = TerminalRegistry.focused()?.id == surface.id
        let (processName, processPid) = getForegroundProcessInfo(for: surface)
        let neighbors = TerminalRegistry.neighbors(for: surface)

        return .object([
            "id": .string(surface.id.uuidString),
            "title": .string(surface.title ?? ""),
            "pwd": surface.pwd.map { .string($0) } ?? .null,
            "window_id": windowId.map { .string($0) } ?? .null,
            "is_focused": .bool(isFocused),
            "is_quick_terminal": .bool(isQuickTerminal),
            "rows": .int(Int(size?.rows ?? 0)),
            "columns": .int(Int(size?.columns ?? 0)),
            "foreground_process_name": processName.map { .string($0) } ?? .null,
            "foreground_process_pid": processPid.map { .int($0) } ?? .null,
            "neighbors": neighborsToJSON(neighbors)
        ])
    }

    /// Get the foreground process info (name and PID) for a surface
    private func getForegroundProcessInfo(for surfaceView: Ghostty.SurfaceView) -> (name: String?, pid: Int?) {
        guard let surface = surfaceView.surface else { return (nil, nil) }

        let pid = ghostty_surface_get_foreground_pid(surface)
        guard pid > 0 else { return (nil, nil) }

        // Use proc_pidpath to get the full path, then extract basename
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))

        let processName: String?
        if pathLength > 0 {
            let path = String(cString: pathBuffer)
            processName = (path as NSString).lastPathComponent
        } else {
            processName = nil
        }

        return (processName, Int(pid))
    }

    private func handleNewWindow(params: [String: JSONValue]) -> JSONValue {
        let command = params["command"]?.stringValue
        let directory = params["directory"]?.stringValue

        if let surfaceId = actionHandler.newWindow(command: command, directory: directory) {
            return .object(["surface_id": .string(surfaceId)])
        }
        return .object(["error": .string("Failed to create window")])
    }

    private func handleNewTab(params: [String: JSONValue]) -> JSONValue {
        let windowId = params["window_id"]?.stringValue
        let command = params["command"]?.stringValue
        let directory = params["directory"]?.stringValue

        if let surfaceId = actionHandler.newTab(windowId: windowId, command: command, directory: directory) {
            return .object(["surface_id": .string(surfaceId)])
        }
        return .object(["error": .string("Failed to create tab")])
    }

    private func handleNewSplit(params: [String: JSONValue]) -> JSONValue {
        guard let surfaceId = params["surface_id"]?.stringValue else {
            return .object(["error": .string("Missing 'surface_id' parameter")])
        }
        guard let direction = params["direction"]?.stringValue else {
            return .object(["error": .string("Missing 'direction' parameter")])
        }

        if let newSurfaceId = actionHandler.newSplit(terminalId: surfaceId, direction: direction) {
            return .object(["surface_id": .string(newSurfaceId)])
        }
        return .object(["error": .string("Failed to create split")])
    }

    private func handleCloseSurface(params: [String: JSONValue]) -> JSONValue {
        guard let surfaceId = params["id"]?.stringValue else {
            return .object(["error": .string("Missing 'id' parameter")])
        }

        let success = actionHandler.closeTerminal(id: surfaceId)
        return .object(["success": .bool(success)])
    }

    private func handleFocusSurface(params: [String: JSONValue]) -> JSONValue {
        guard let surfaceId = params["id"]?.stringValue else {
            return .object(["error": .string("Missing 'id' parameter")])
        }

        let success = actionHandler.focusTerminal(id: surfaceId)
        return .object(["success": .bool(success)])
    }

    private func handleSendText(params: [String: JSONValue]) -> JSONValue {
        guard let surfaceId = params["surface_id"]?.stringValue else {
            return .object(["error": .string("Missing 'surface_id' parameter")])
        }
        guard let text = params["text"]?.stringValue else {
            return .object(["error": .string("Missing 'text' parameter")])
        }

        let success = actionHandler.sendText(terminalId: surfaceId, text: text)
        return .object(["success": .bool(success)])
    }

    private func handleAction(params: [String: JSONValue]) -> JSONValue {
        guard let action = params["action"]?.stringValue else {
            return .object(["error": .string("Missing 'action' parameter")])
        }

        let surfaceId = params["surface_id"]?.stringValue
        let success = actionHandler.performAction(terminalId: surfaceId, action: action)
        return .object(["success": .bool(success)])
    }

    private func handleReloadConfig() -> JSONValue {
        let success = actionHandler.reloadConfig()
        return .object(["success": .bool(success)])
    }

    private func handleToggleQuickTerminal() -> JSONValue {
        let success = actionHandler.toggleQuickTerminal()
        return .object(["success": .bool(success)])
    }

    private func handleToggleVisibility() -> JSONValue {
        let success = actionHandler.toggleVisibility()
        return .object(["success": .bool(success)])
    }

    private func handleWriteScreenFile(params: [String: JSONValue]) -> JSONValue {
        guard let surfaceId = params["surface_id"]?.stringValue else {
            return .object(["error": .string("Missing 'surface_id' parameter")])
        }

        guard let path = actionHandler.writeScreenFile(surfaceId: surfaceId) else {
            return .object(["error": .string("Surface not found or failed to write")])
        }

        return .object(["path": .string(path)])
    }
}
