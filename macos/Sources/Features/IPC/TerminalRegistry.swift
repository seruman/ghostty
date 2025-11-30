import Foundation
import AppKit
import GhosttyKit

/// Neighbor surface IDs in each direction
struct Neighbors: Codable {
    let left: String?
    let right: String?
    let up: String?
    let down: String?
}

/// Information about a terminal for IPC responses
struct TerminalInfo: Codable {
    let id: String
    let title: String
    let pwd: String?
    let windowId: String?
    let isFocused: Bool
    let isQuickTerminal: Bool
    let rows: Int
    let columns: Int
    let foregroundProcessName: String?
    let foregroundProcessPid: Int?
    let neighbors: Neighbors?
}

/// Provides access to all terminals across all windows for IPC operations
@MainActor
final class TerminalRegistry {

    /// Get all terminals across all windows
    static func allTerminals() -> [TerminalInfo] {
        var terminals: [TerminalInfo] = []

        for controller in TerminalController.all {
            let windowId = controller.window?.windowNumber
            let windowIdStr = windowId.map { String($0) }

            // Compute neighbors for all surfaces in this window
            let neighborsMap = computeNeighbors(for: controller.surfaceTree)

            for surfaceView in controller.surfaceTree {
                let neighbors = neighborsMap[surfaceView.id]
                let info = terminalInfo(from: surfaceView, windowId: windowIdStr, neighbors: neighbors)
                terminals.append(info)
            }
        }

        // Also check quick terminal (only if already initialized to avoid lazy init)
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.isQuickTerminalInitialized {
            let neighborsMap = computeNeighbors(for: appDelegate.quickController.surfaceTree)

            for surfaceView in appDelegate.quickController.surfaceTree {
                let neighbors = neighborsMap[surfaceView.id]
                let info = terminalInfo(from: surfaceView, windowId: "quick", isQuickTerminal: true, neighbors: neighbors)
                terminals.append(info)
            }
        }

        return terminals
    }

    /// Find a terminal by UUID
    static func find(id: UUID) -> Ghostty.SurfaceView? {
        // Check regular terminal controllers
        for controller in TerminalController.all {
            for surfaceView in controller.surfaceTree {
                if surfaceView.id == id {
                    return surfaceView
                }
            }
        }

        // Check quick terminal (only if already initialized to avoid lazy init)
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.isQuickTerminalInitialized {
            for surfaceView in appDelegate.quickController.surfaceTree {
                if surfaceView.id == id {
                    return surfaceView
                }
            }
        }

        return nil
    }

    /// Find a terminal by string ID
    static func find(idString: String) -> Ghostty.SurfaceView? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return find(id: uuid)
    }

    /// Get the currently focused terminal
    static func focused() -> Ghostty.SurfaceView? {
        // Try the key window first
        if let window = NSApp.keyWindow,
           let controller = window.windowController as? TerminalController {
            return controller.focusedSurface
        }

        // Check quick terminal if it's visible
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.quickController.visible {
            return appDelegate.quickController.focusedSurface
        }

        // Fall back to any controller with focus
        for controller in TerminalController.all {
            if let focused = controller.focusedSurface {
                return focused
            }
        }

        return nil
    }

    /// Get the TerminalController for a given surface
    static func controller(for surfaceView: Ghostty.SurfaceView) -> TerminalController? {
        return surfaceView.window?.windowController as? TerminalController
    }

    /// Create TerminalInfo from a surface view
    private static func terminalInfo(
        from surfaceView: Ghostty.SurfaceView,
        windowId: String?,
        isQuickTerminal: Bool = false,
        neighbors: Neighbors? = nil
    ) -> TerminalInfo {
        let size = surfaceView.surfaceSize
        let focused = (NSApp.keyWindow?.windowController as? TerminalController)?.focusedSurface?.id == surfaceView.id

        // Get foreground process info
        let (processName, processPid) = getForegroundProcessInfo(for: surfaceView)

        return TerminalInfo(
            id: surfaceView.id.uuidString,
            title: surfaceView.title ?? "",
            pwd: surfaceView.pwd,
            windowId: windowId,
            isFocused: focused,
            isQuickTerminal: isQuickTerminal,
            rows: Int(size?.rows ?? 0),
            columns: Int(size?.columns ?? 0),
            foregroundProcessName: processName,
            foregroundProcessPid: processPid,
            neighbors: neighbors
        )
    }

    /// Compute neighbors for all surfaces in a split tree
    private static func computeNeighbors(for tree: SplitTree<Ghostty.SurfaceView>) -> [UUID: Neighbors] {
        var result: [UUID: Neighbors] = [:]

        guard let root = tree.root else { return result }

        // Get spatial representation once
        let spatial = root.spatial()

        // Build a map from view to its slot for quick lookup
        var viewToSlot: [ObjectIdentifier: SplitTree<Ghostty.SurfaceView>.Spatial.Slot] = [:]
        for slot in spatial.slots {
            if case .leaf(let view) = slot.node {
                viewToSlot[ObjectIdentifier(view)] = slot
            }
        }

        // For each leaf surface, find neighbors in all directions
        for surfaceView in tree {
            guard let refSlot = viewToSlot[ObjectIdentifier(surfaceView)] else { continue }

            let left = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .left)
            let right = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .right)
            let up = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .up)
            let down = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .down)

            result[surfaceView.id] = Neighbors(
                left: left?.id.uuidString,
                right: right?.id.uuidString,
                up: up?.id.uuidString,
                down: down?.id.uuidString
            )
        }

        return result
    }

    /// Find the nearest leaf neighbor in a direction using slot bounds directly
    private static func findNeighborLeaf(
        spatial: SplitTree<Ghostty.SurfaceView>.Spatial,
        refSlot: SplitTree<Ghostty.SurfaceView>.Spatial.Slot,
        direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
    ) -> Ghostty.SurfaceView? {
        // Filter and find candidates based on direction
        var candidates: [(view: Ghostty.SurfaceView, distance: Double)] = []

        for slot in spatial.slots {
            // Only consider leaf nodes
            guard case .leaf(let view) = slot.node else { continue }

            // Skip self
            if case .leaf(let refView) = refSlot.node, view === refView { continue }

            // Check if slot is in the requested direction
            let isInDirection: Bool
            switch direction {
            case .left:
                isInDirection = slot.bounds.maxX <= refSlot.bounds.minX
            case .right:
                isInDirection = slot.bounds.minX >= refSlot.bounds.maxX
            case .up:
                isInDirection = slot.bounds.maxY <= refSlot.bounds.minY
            case .down:
                isInDirection = slot.bounds.minY >= refSlot.bounds.maxY
            }

            guard isInDirection else { continue }

            // Calculate distance
            let dx = slot.bounds.minX - refSlot.bounds.minX
            let dy = slot.bounds.minY - refSlot.bounds.minY
            let distance = sqrt(dx * dx + dy * dy)

            candidates.append((view, distance))
        }

        // Return the closest one
        return candidates.min(by: { $0.distance < $1.distance })?.view
    }

    /// Get neighbors for a single surface
    static func neighbors(for surfaceView: Ghostty.SurfaceView) -> Neighbors? {
        // Find the controller containing this surface
        let controller: BaseTerminalController?
        if let termController = surfaceView.window?.windowController as? TerminalController {
            controller = termController
        } else if let appDelegate = NSApp.delegate as? AppDelegate,
                  appDelegate.isQuickTerminalInitialized,
                  appDelegate.quickController.surfaceTree.contains(where: { $0.id == surfaceView.id }) {
            controller = appDelegate.quickController
        } else {
            return nil
        }

        guard let controller,
              let root = controller.surfaceTree.root else {
            return nil
        }

        let spatial = root.spatial()

        // Find the slot for this surface by view identity
        guard let refSlot = spatial.slots.first(where: {
            if case .leaf(let view) = $0.node {
                return view === surfaceView
            }
            return false
        }) else {
            return nil
        }

        let left = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .left)
        let right = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .right)
        let up = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .up)
        let down = findNeighborLeaf(spatial: spatial, refSlot: refSlot, direction: .down)

        return Neighbors(
            left: left?.id.uuidString,
            right: right?.id.uuidString,
            up: up?.id.uuidString,
            down: down?.id.uuidString
        )
    }

    /// Get the foreground process info (name and PID) for a surface
    private static func getForegroundProcessInfo(for surfaceView: Ghostty.SurfaceView) -> (name: String?, pid: Int?) {
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
}
