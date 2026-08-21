import Foundation

/// Persisted widths for the size and date columns. The name column always
/// fills the remaining space. Both panes share the same keys (TC behavior).
final class PaneColumnLayout {
    static let defaultSize: CGFloat = 72
    static let defaultDate: CGFloat = 160
    static let minSize: CGFloat = 40
    static let maxSize: CGFloat = 400
    static let minDate: CGFloat = 80
    static let maxDate: CGFloat = 400

    private let defaults: UserDefaults
    private static let sizeKey = "fc.col.size"
    private static let dateKey = "fc.col.date"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var sizeWidth: CGFloat {
        get {
            let v = defaults.double(forKey: Self.sizeKey)
            return v == 0 ? Self.defaultSize : CGFloat(v).clamped(to: Self.minSize...Self.maxSize)
        }
        set {
            defaults.set(Double(newValue.clamped(to: Self.minSize...Self.maxSize)), forKey: Self.sizeKey)
        }
    }

    var dateWidth: CGFloat {
        get {
            let v = defaults.double(forKey: Self.dateKey)
            return v == 0 ? Self.defaultDate : CGFloat(v).clamped(to: Self.minDate...Self.maxDate)
        }
        set {
            defaults.set(Double(newValue.clamped(to: Self.minDate...Self.maxDate)), forKey: Self.dateKey)
        }
    }
}

private extension CGFloat {
    func clamped(to r: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}
