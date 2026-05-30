import SwiftUI

// MARK: - ActionCategory

enum ActionCategory: String, Codable, CaseIterable, Identifiable {
    case xcode   = "Xcode"
    case system  = "System"
    case network = "Network"
    case halo    = "Halo"
    case custom  = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .xcode:   return "hammer.fill"
        case .system:  return "gearshape.2.fill"
        case .network: return "network"
        case .halo:    return "sparkles"
        case .custom:  return "terminal.fill"
        }
    }

    var color: Color {
        switch self {
        case .xcode:   return Color(hex: "#4f7cff")
        case .system:  return Color(hex: "#22d97a")
        case .network: return Color(hex: "#00d4e8")
        case .halo:    return Color(hex: "#7b5ea7")
        case .custom:  return Color(hex: "#f5a623")
        }
    }
}

// MARK: - BuiltInAction

enum BuiltInAction: String, Codable, CaseIterable {
    case runSmartScan
    case runSpeedTest
    case clearClipboard
    case exportReport
}

// MARK: - ActionCommand

enum ActionCommand: Codable, Equatable {
    case builtIn(BuiltInAction)
    /// Single command or multi-line shell script. Treated as /bin/zsh -c input.
    case shell(String)

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        let v = try c.decode(String.self, forKey: .value)
        switch t {
        case "builtIn": self = .builtIn(BuiltInAction(rawValue: v) ?? .runSmartScan)
        default:        self = .shell(v)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn(let a): try c.encode("builtIn", forKey: .type); try c.encode(a.rawValue, forKey: .value)
        case .shell(let s):   try c.encode("shell",   forKey: .type); try c.encode(s, forKey: .value)
        }
    }
}

// MARK: - ActionItem

struct ActionItem: Identifiable, Codable, Equatable {
    var id:               UUID          = UUID()
    var name:             String
    var subtitle:         String
    var icon:             String        // SF Symbol name
    var iconColorHex:     String        // hex string e.g. "#4f7cff"
    var category:         ActionCategory
    /// Lower-cased search aliases used for fuzzy matching.
    var keywords:         [String]
    var command:          ActionCommand
    /// If true, the shell command will be run with administrator privileges via osascript.
    var requiresPrivilege: Bool         = false
    var isBuiltIn:        Bool          = true
    var isPinned:         Bool          = false
    var usageCount:       Int           = 0
    var lastUsed:         Date?         = nil

    var iconColor: Color { Color(hex: iconColorHex) }
}

// MARK: - ActionExecutionState

enum ActionExecutionState: Equatable {
    case queued
    case running
    case completed
    case failed(String)

    var isFinished: Bool {
        switch self { case .completed, .failed: return true; default: return false }
    }

    var label: String {
        switch self {
        case .queued:      return "Queued"
        case .running:     return "Running"
        case .completed:   return "Completed"
        case .failed(let msg): return msg.isEmpty ? "Failed" : msg
        }
    }

    var color: Color {
        switch self {
        case .queued:    return .haloText3
        case .running:   return .haloAmber
        case .completed: return .haloGreen
        case .failed:    return .haloRed
        }
    }

    var icon: String {
        switch self {
        case .queued:    return "clock"
        case .running:   return "arrow.trianglehead.2.clockwise"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }
}

// MARK: - ActionExecution

struct ActionExecution: Identifiable {
    let id:              UUID   = UUID()
    let actionId:        UUID
    let actionName:      String
    let actionIcon:      String
    let actionIconColor: String
    let startDate:       Date
    var endDate:         Date?
    var state:           ActionExecutionState = .running
    /// Streamed stdout/stderr lines.
    var outputLines:     [String]             = []
    /// -1 = indeterminate, 0.0–1.0 = determinate progress.
    var progress:        Double               = -1

    var duration: String {
        let end = endDate ?? Date()
        let s = end.timeIntervalSince(startDate)
        if s < 60 { return String(format: "%.1fs", s) }
        return String(format: "%dm %ds", Int(s) / 60, Int(s) % 60)
    }

    var lastOutputLine: String { outputLines.last ?? "" }
}
