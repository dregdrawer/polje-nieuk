import Foundation

public enum ParamKind: Equatable, Sendable {
    case continuous
    case integer
    case toggle
    case choice([String])
    case trigger
}

public enum ParamCurve: Sendable { case linear, exponential, cubic }

public struct ParamSpec: Sendable {
    public let key: String
    public let name: String
    public let min: Float
    public let max: Float
    public let def: Float
    public let unit: String
    public let kind: ParamKind
    public let curve: ParamCurve
    /// Only these values (ascending): the row slides through them evenly (seq~ length: 1…16, 32, 64).
    public var allowed: [Float]? = nil

    public init(_ key: String, _ name: String, _ min: Float, _ max: Float, _ def: Float,
                unit: String = "", kind: ParamKind = .continuous, curve: ParamCurve = .linear) {
        self.key = key; self.name = name; self.min = min; self.max = max; self.def = def
        self.unit = unit; self.kind = kind; self.curve = curve
    }

    static func choice(_ key: String, _ name: String, _ options: [String], def: Int) -> ParamSpec {
        ParamSpec(key, name, 0, Float(options.count - 1), Float(def), kind: .choice(options))
    }
    static func toggle(_ key: String, _ name: String, _ on: Bool) -> ParamSpec {
        ParamSpec(key, name, 0, 1, on ? 1 : 0, kind: .toggle)
    }
    static func trigger(_ key: String, _ name: String) -> ParamSpec {
        ParamSpec(key, name, 0, 1, 0, kind: .trigger)
    }
    static func integer(_ key: String, _ name: String, _ min: Int, _ max: Int, _ def: Int) -> ParamSpec {
        ParamSpec(key, name, Float(min), Float(max), Float(def), kind: .integer)
    }

    public var isTrigger: Bool { if case .trigger = kind { return true }; return false }

    /// The nearest allowed value (for parameters with a fixed list; otherwise `v`).
    public func snapped(_ v: Float) -> Float {
        guard let a = allowed, !a.isEmpty, v.isFinite else { return v }
        return a.min { abs($0 - v) < abs($1 - v) } ?? v
    }

    public func normalized(_ v: Float) -> Float {
        guard v.isFinite else { return 0 }
        if let a = allowed, a.count > 1 {
            let s = snapped(v)
            return Float(a.firstIndex(of: s) ?? 0) / Float(a.count - 1)
        }
        let n: Float
        switch curve {
        case .linear: n = (v - min) / (max - min)
        case .exponential: n = log(Swift.max(v, min) / min) / log(max / min)
        case .cubic:
            if min >= 0 {
                // a 0 … max setting (times): fine control near 0, the whole slider in use
                n = max > 0 ? cbrt(Swift.max(v, 0) / max) : 0
            } else {
                let a = Swift.max(abs(min), abs(max))
                n = (cbrt(v / a) + 1) / 2
            }
        }
        return n.isFinite ? Swift.min(Swift.max(n, 0), 1) : 0
    }

    public func value(fromNormalized n: Float) -> Float {
        let c = n.isFinite ? Swift.min(Swift.max(n, 0), 1) : 0
        if let a = allowed, a.count > 1 { return a[Swift.min(Int((c * Float(a.count - 1)).rounded()), a.count - 1)] }
        var v: Float
        switch curve {
        case .linear: v = min + (max - min) * c
        case .exponential: v = min * pow(max / min, c)
        case .cubic:
            if min >= 0 {
                v = max * c * c * c
            } else {
                let a = Swift.max(abs(min), abs(max)), x = 2 * c - 1
                v = a * x * x * x
            }
        }
        switch kind {
        case .integer, .choice, .toggle, .trigger: v = v.rounded()
        case .continuous: break
        }
        return Swift.min(Swift.max(v, min), max)
    }

    public func display(_ v: Float) -> String {
        guard v.isFinite else { return "—" }
        switch kind {
        case .toggle: return v > 0.5 ? "on" : "off"
        case .trigger: return ""
        case .choice(let options):
            let i = clampIndex(v, options.count)
            return options[i]
        case .integer: return "\(Int(Swift.min(Swift.max(v, -1e9), 1e9).rounded()))"
        case .continuous:
            switch unit {
            case "Hz":
                if v < 0 { return "-" + display(-v) }
                if v >= 1000 { return String(format: "%.1fk", v / 1000) }
                if v >= 100 { return String(format: "%.0f", v) }
                if v >= 10 { return String(format: "%.1f", v) }
                return String(format: "%.2f", v)
            case "ms":
                if v >= 1000 { return String(format: "%.2fs", v / 1000) }
                if v >= 10 { return String(format: "%.0fms", v) }
                return String(format: "%.1fms", v)
            case "%": return String(format: "%.0f%%", v * 100)
            case "dB": return v <= min + 0.05 && min <= -59 ? "-inf" : String(format: "%+.1fdB", v)
            case "st": return String(format: "%+.1fst", v)
            case "/s": return String(format: "%.1f/s", v)
            case "bpm": return String(format: "%.1f", v)
            case ":1": return String(format: "%.1f:1", v)
            case "°": return String(format: "%.0f°", v)
            case "x": return String(format: "%.2fx", v)
            case "bit": return String(format: "%.1f bit", v)
            case "ct": return String(format: "%+.0fct", v)
            default: return String(format: "%.2f", v)
            }
        }
    }
}

public enum BypassMode: Sendable {
    case through   // bypassed: audio passes straight through
    case silent    // bypassed: outputs silence (modulation sources)
    case none      // no bypass button (in~, out~, clock, rec~, mix~)
}

public struct ModuleSpec {
    public let kind: String
    public let name: String
    public let category: String
    public let summary: String
    public let aliases: [String]
    public let inputs: [String]
    public let outputs: [String]
    public let params: [ParamSpec]
    public let factory: (ModuleSpec, Double) -> DSPNode
    /// Outlets whose cable can carry several notes at once (a chord from roll~ / chord~). Note 1 (the lowest)
    /// is what a mono module reads, so they work as before anywhere else.
    public var polyOutputs: [Int] = []

    public func paramIndex(_ key: String) -> Int? { params.firstIndex { $0.key == key } }

    public var bypass: BypassMode {
        switch kind {
        case "in", "out", "clock", "rec", "mix", "text", "scope": return .none
        case "atten": return .through
        case "macro", "modal", "shapes", "rack", "drumsynth", "wave": return .silent       // sound sources: bypass = mute
        case "keys", "seq", "turing", "roll", "drums", "slider", "knob", "chord": return .silent
        default: return category == "Modulation" ? .silent : .through
        }
    }

    /// Control voltages (pitch, gates, clocks, LFOs, envelopes …) rather than audio: out~'s gain leaves
    /// these alone, so pitch stays exactly 1 V/oct and gates keep their level.
    public var outputsAreCV: Bool { ["Sequencing", "Modulation", "Clock"].contains(category) }

    /// For each outlet, which inlet feeds it when bypassed (-1 = silence).
    /// L/R inlets map straight across; everything else takes the first inlet.
    var bypassRouting: [Int] {
        outputs.indices.map { k in
            if bypass != .through || inputs.isEmpty { return -1 }
            if outputs[k].hasSuffix("R"), let r = inputs.firstIndex(of: "R") { return r }
            if outputs[k].hasSuffix("L"), let l = inputs.firstIndex(of: "L") { return l }
            return 0
        }
    }
}
