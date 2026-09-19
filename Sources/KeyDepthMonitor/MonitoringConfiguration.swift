import Foundation

struct MonitoredKey: Codable, Equatable, Identifiable {
    let index: Int
    var label: String
    var fullPressDepth: Int

    var id: Int { index }

    static let defaults: [MonitoredKey] = [
        MonitoredKey(index: 4, label: "Shift", fullPressDepth: 718),
        MonitoredKey(index: 9, label: "A", fullPressDepth: 716),
        MonitoredKey(index: 14, label: "W", fullPressDepth: 720),
        MonitoredKey(index: 15, label: "S", fullPressDepth: 715),
        MonitoredKey(index: 20, label: "E", fullPressDepth: 716),
        MonitoredKey(index: 21, label: "D", fullPressDepth: 718),
        MonitoredKey(index: 26, label: "R", fullPressDepth: 720),
        MonitoredKey(index: 41, label: "Space", fullPressDepth: 720)
    ]
}

enum MonitoringPreferences {
    static let monitoredKeysKey = "monitoredKeys.v1"
    static let showUnconfiguredKey = "showUnconfiguredKeys.v1"
    static let keyboardSuppressionScopeKey = "keyboardSuppressionScope.v1"

    static func loadKeys(from defaults: UserDefaults) -> [MonitoredKey] {
        guard let data = defaults.data(forKey: monitoredKeysKey),
              let decoded = try? JSONDecoder().decode([MonitoredKey].self, from: data) else {
            return MonitoredKey.defaults
        }
        var unique: [Int: MonitoredKey] = [:]
        for key in decoded where (0...255).contains(key.index) && (1...65535).contains(key.fullPressDepth) {
            let label = key.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            unique[key.index] = MonitoredKey(
                index: key.index,
                label: label,
                fullPressDepth: key.fullPressDepth
            )
        }
        return unique.values.sorted { $0.index < $1.index }
    }

    static func saveKeys(_ keys: [MonitoredKey], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        defaults.set(data, forKey: monitoredKeysKey)
    }
}
