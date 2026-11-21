import Foundation

/// fm's 32 built-in voices: our own, in the classic DX7 styles (e-pianos, brass, strings, basses, bells,
/// organs, plucks, winds, leads, pads). Each is a plain DX7 voice, so it edits like any other and could be
/// saved into a bank.
public enum FMPresets {
    public struct Preset: Sendable { public let name: String; public let vced: [UInt8] }

    /// One operator: frequency (coarse / fine, ratio or fixed), output level, envelope, velocity, rate scaling.
    struct Op {
        var fc = 1, ff = 0, ol = 99
        var r = [99, 99, 99, 99], l = [99, 99, 99, 0]
        var kvs = 0, rs = 0, dt = 0, fixed = false, ams = 0
        var bp = 39, ld = 0, rd = 0, lc = 0, rc = 0
    }
    struct LFO { var speed = 35, delay = 0, pmd = 0, amd = 0, wave = 0, pms = 3, sync = false }

    static func voice(_ name: String, alg: Int, fb: Int, transpose: Int = 0, lfo: LFO = LFO(),
                      pitch: (r: [Int], l: [Int]) = ([99, 99, 99, 99], [50, 50, 50, 50]), oks: Bool = true,
                      _ ops: [Op]) -> Preset {
        var v = [UInt8](repeating: 0, count: 155)
        for (k, o) in ops.prefix(6).enumerated() {
            let s = (5 - k) * 21                                  // the sysex keeps op 6 first
            for i in 0..<4 { v[s + i] = UInt8(o.r[i]); v[s + 4 + i] = UInt8(o.l[i]) }
            v[s + 8] = UInt8(o.bp); v[s + 9] = UInt8(o.ld); v[s + 10] = UInt8(o.rd)
            v[s + 11] = UInt8(o.lc); v[s + 12] = UInt8(o.rc); v[s + 13] = UInt8(o.rs)
            v[s + 14] = UInt8(o.ams); v[s + 15] = UInt8(o.kvs); v[s + 16] = UInt8(o.ol)
            v[s + 17] = o.fixed ? 1 : 0; v[s + 18] = UInt8(o.fc); v[s + 19] = UInt8(o.ff); v[s + 20] = UInt8(o.dt + 7)
        }
        for i in 0..<4 { v[126 + i] = UInt8(pitch.r[i]); v[130 + i] = UInt8(pitch.l[i]) }
        v[134] = UInt8(alg - 1); v[135] = UInt8(fb); v[136] = oks ? 1 : 0
        v[137] = UInt8(lfo.speed); v[138] = UInt8(lfo.delay); v[139] = UInt8(lfo.pmd); v[140] = UInt8(lfo.amd)
        v[141] = lfo.sync ? 1 : 0; v[142] = UInt8(lfo.wave); v[143] = UInt8(lfo.pms)
        v[144] = UInt8(24 + transpose)
        let n = Array(name.uppercased().utf8.prefix(10)) + [UInt8](repeating: 32, count: 10)
        for i in 0..<10 { v[145 + i] = n[i] }
        return Preset(name: name, vced: v)
    }

    // MARK: families

    /// Electric piano: three carrier / modulator pairs (algorithm 5); a high "tine" ratio on one modulator.
    static func epiano(_ name: String, tine: Int, tineLevel: Int, body: Int, decay: Int, fb: Int = 6) -> Preset {
        voice(name, alg: 5, fb: fb, lfo: LFO(speed: 34, pmd: 0, amd: 0, pms: 3), [
            Op(fc: 1, ol: 99, r: [96, decay, 25, 67], l: [99, 75, 0, 0], kvs: 2, rs: 3, dt: 3),
            Op(fc: 1, ol: body, r: [95, 50, 35, 78], l: [99, 75, 0, 0], kvs: 7, rs: 3),
            Op(fc: 1, ol: 99, r: [95, decay - 5, 20, 50], l: [99, 95, 0, 0], kvs: 2, rs: 3, dt: -3),
            Op(fc: tine, ol: tineLevel, r: [95, 29, 20, 50], l: [99, 95, 0, 0], kvs: 7, rs: 3),
            Op(fc: 1, ol: 92, r: [95, decay - 5, 20, 50], l: [99, 95, 0, 0], kvs: 2, rs: 3),
            Op(fc: 1, ol: 72, r: [95, 29, 20, 50], l: [99, 95, 0, 0], kvs: 6, rs: 3)])
    }

    /// Brass: one feedback modulator over three detuned carriers (algorithm 22), a slow-ish attack.
    static func brass(_ name: String, attack: Int, bright: Int, release: Int = 60, sweep: Bool = true) -> Preset {
        voice(name, alg: 22, fb: 7, lfo: LFO(speed: 37, delay: 30, pmd: 5, pms: 3),
              pitch: sweep ? ([84, 95, 95, 60], [47, 50, 50, 50]) : ([99, 99, 99, 99], [50, 50, 50, 50]), [
            Op(fc: 1, ol: 98, r: [attack, 76, 99, release], l: [99, 88, 96, 0], kvs: 1, rs: 2),
            Op(fc: 1, ol: bright - 6, r: [attack - 10, 51, 29, release], l: [82, 95, 96, 0], kvs: 3),
            Op(fc: 1, ol: 98, r: [attack, 76, 99, release], l: [99, 88, 96, 0], kvs: 1, rs: 2, dt: 2),
            Op(fc: 1, ol: 98, r: [attack, 76, 99, release], l: [99, 88, 96, 0], kvs: 1, rs: 2, dt: -2),
            Op(fc: 1, ol: 94, r: [attack, 76, 99, release], l: [99, 88, 96, 0], kvs: 1, rs: 2, dt: 1),
            Op(fc: 1, ol: bright, r: [attack + 5, 36, 41, release], l: [99, 98, 98, 0], kvs: 4)])
    }

    /// Strings / pads: two stacks (algorithm 1), slow attack and release, gently detuned, vibrato.
    static func pad(_ name: String, attack: Int, release: Int, ratio: Int, bright: Int, lfoSpeed: Int = 30, pmd: Int = 6) -> Preset {
        voice(name, alg: 1, fb: 5, lfo: LFO(speed: lfoSpeed, delay: 40, pmd: pmd, amd: 0, wave: 4, pms: 3), [
            Op(fc: 1, ol: 99, r: [attack, 24, 20, release], l: [99, 90, 88, 0], kvs: 1, dt: 3),
            Op(fc: ratio, ol: bright, r: [attack + 4, 36, 20, release], l: [99, 85, 80, 0], kvs: 2),
            Op(fc: 1, ol: 97, r: [attack, 24, 20, release], l: [99, 90, 88, 0], kvs: 1, dt: -3),
            Op(fc: 1, ol: bright - 4, r: [attack + 4, 40, 20, release], l: [99, 86, 82, 0], kvs: 2, dt: 2),
            Op(fc: 3, ol: bright - 14, r: [attack + 8, 30, 20, release], l: [99, 80, 75, 0]),
            Op(fc: 1, ol: bright - 10, r: [attack + 8, 30, 20, release], l: [99, 80, 75, 0])])
    }

    /// Bass: a single stack into one carrier (algorithm 16), plucky.
    static func bass(_ name: String, ratio: Int, bright: Int, decay: Int, fb: Int, sustain: Int = 0) -> Preset {
        voice(name, alg: 16, fb: fb, transpose: -12, [
            Op(fc: 1, ol: 99, r: [99, decay, 25, 70], l: [99, 85, sustain, 0], kvs: 2, rs: 2),
            Op(fc: ratio, ol: bright, r: [99, decay + 10, 30, 70], l: [99, 70, 0, 0], kvs: 5, rs: 2),
            Op(fc: 1, ol: bright - 8, r: [99, decay + 5, 30, 70], l: [99, 75, 0, 0], kvs: 5),
            Op(fc: 2, ol: bright - 20, r: [99, 60, 30, 70], l: [99, 60, 0, 0], kvs: 6),
            Op(fc: 1, ol: bright - 12, r: [99, decay + 8, 30, 70], l: [99, 70, 0, 0], kvs: 5),
            Op(fc: 1, ol: bright - 18, r: [99, 70, 30, 70], l: [99, 60, 0, 0], kvs: 6)])
    }

    /// Bells: carrier / modulator pairs with inharmonic ratios and long decays (algorithm 5).
    static func bell(_ name: String, mods: [(Int, Int)], decay: Int, level: Int) -> Preset {
        let m = mods + Array(repeating: (3, 0), count: max(0, 3 - mods.count))
        return voice(name, alg: 5, fb: 0, [
            Op(fc: 1, ol: 99, r: [99, decay, 20, 40], l: [99, 0, 0, 0], kvs: 2, rs: 2),
            Op(fc: m[0].0, ff: m[0].1, ol: level, r: [99, decay - 4, 20, 40], l: [99, 0, 0, 0], kvs: 4, rs: 2),
            Op(fc: 2, ol: 90, r: [99, decay + 6, 20, 40], l: [99, 0, 0, 0], kvs: 2, rs: 2),
            Op(fc: m[1].0, ff: m[1].1, ol: level - 6, r: [99, decay, 20, 40], l: [99, 0, 0, 0], kvs: 4, rs: 2),
            Op(fc: 4, ol: 84, r: [99, decay + 10, 20, 40], l: [99, 0, 0, 0], kvs: 2, rs: 2),
            Op(fc: m[2].0, ff: m[2].1, ol: level - 10, r: [99, decay + 4, 20, 40], l: [99, 0, 0, 0], kvs: 4, rs: 2)])
    }

    /// Organ: six sine "drawbars" (algorithm 32), instant on / off.
    static func organ(_ name: String, drawbars: [(Int, Int)], fb: Int = 0, click: Bool = false) -> Preset {
        let ops = drawbars.prefix(6).map { d in
            Op(fc: d.0, ol: d.1, r: [99, click ? 60 : 99, 99, 85], l: [99, click ? 88 : 99, click ? 88 : 99, 0])
        }
        return voice(name, alg: 32, fb: fb, lfo: LFO(speed: 66, pmd: 2, amd: 0, wave: 4, pms: 2), ops)
    }

    /// Plucked strings / mallets: two stacks (algorithm 3), fast decays.
    static func pluck(_ name: String, ratio: Int, bright: Int, decay: Int, fb: Int, ratio2: Int = 1) -> Preset {
        voice(name, alg: 3, fb: fb, [
            Op(fc: 1, ol: 99, r: [99, decay, 20, 60], l: [99, 0, 0, 0], kvs: 3, rs: 3),
            Op(fc: ratio, ol: bright, r: [99, decay + 6, 20, 60], l: [99, 0, 0, 0], kvs: 5, rs: 3),
            Op(fc: ratio2, ol: bright - 10, r: [99, decay + 12, 20, 60], l: [99, 0, 0, 0], kvs: 5, rs: 3),
            Op(fc: 1, ol: 92, r: [99, decay - 3, 20, 60], l: [99, 0, 0, 0], kvs: 3, rs: 3, dt: 2),
            Op(fc: ratio, ol: bright - 4, r: [99, decay + 8, 20, 60], l: [99, 0, 0, 0], kvs: 5, rs: 3),
            Op(fc: 1, ol: bright - 16, r: [99, decay + 14, 20, 60], l: [99, 0, 0, 0], kvs: 6, rs: 3)])
    }

    /// Winds: one carrier with gentle modulation and a breathy, slightly noisy feedback op (algorithm 2).
    static func wind(_ name: String, ratio: Int, bright: Int, breath: Int, attack: Int = 60) -> Preset {
        voice(name, alg: 2, fb: 7, lfo: LFO(speed: 35, delay: 50, pmd: 8, amd: 0, wave: 4, pms: 3), [
            Op(fc: 1, ol: 99, r: [attack, 40, 30, 65], l: [99, 92, 90, 0], kvs: 2),
            Op(fc: ratio, ol: breath, r: [attack + 10, 40, 30, 65], l: [99, 80, 70, 0], kvs: 3),
            Op(fc: 1, ol: 90, r: [attack, 40, 30, 65], l: [99, 92, 90, 0], kvs: 2),
            Op(fc: ratio, ol: bright, r: [attack + 5, 40, 30, 65], l: [99, 85, 80, 0], kvs: 3),
            Op(fc: 1, ol: bright - 8, r: [attack + 5, 40, 30, 65], l: [99, 85, 80, 0], kvs: 3),
            Op(fc: 1, ol: bright - 12, r: [attack + 5, 40, 30, 65], l: [99, 85, 80, 0], kvs: 3)])
    }

    /// Leads: a hard-driven feedback stack (algorithm 1) — saw / square-ish.
    static func lead(_ name: String, ratio: Int, bright: Int, fb: Int, portamentoish: Bool = false) -> Preset {
        voice(name, alg: 1, fb: fb, lfo: LFO(speed: 40, delay: 45, pmd: 10, wave: 4, pms: 3),
              pitch: portamentoish ? ([80, 99, 99, 99], [46, 50, 50, 50]) : ([99, 99, 99, 99], [50, 50, 50, 50]), [
            Op(fc: 1, ol: 99, r: [99, 50, 40, 70], l: [99, 95, 92, 0], kvs: 1),
            Op(fc: ratio, ol: bright, r: [99, 45, 35, 70], l: [99, 90, 85, 0], kvs: 2),
            Op(fc: 1, ol: 96, r: [99, 50, 40, 70], l: [99, 95, 92, 0], kvs: 1, dt: 4),
            Op(fc: 1, ol: bright - 6, r: [99, 45, 35, 70], l: [99, 90, 85, 0], kvs: 2),
            Op(fc: 1, ol: bright - 4, r: [99, 45, 35, 70], l: [99, 90, 85, 0], kvs: 2),
            Op(fc: 1, ol: bright, r: [99, 45, 35, 70], l: [99, 90, 85, 0], kvs: 2)])
    }

    public static let all: [Preset] = [
        epiano("E.Piano 1", tine: 14, tineLevel: 89, body: 58, decay: 25),
        epiano("E.Piano 2", tine: 3, tineLevel: 75, body: 70, decay: 30, fb: 4),
        epiano("Tine Piano", tine: 17, tineLevel: 94, body: 52, decay: 22, fb: 7),
        brass("Brass 1", attack: 72, bright: 86),
        brass("Brass 2", attack: 60, bright: 92, release: 50),
        brass("Soft Horns", attack: 55, bright: 76, release: 55, sweep: false),
        pad("Strings 1", attack: 52, release: 55, ratio: 1, bright: 75),
        pad("Strings 2", attack: 46, release: 52, ratio: 2, bright: 80, pmd: 8),
        pad("Warm Pad", attack: 40, release: 50, ratio: 1, bright: 68, lfoSpeed: 22, pmd: 4),
        pad("Glass Pad", attack: 44, release: 50, ratio: 4, bright: 72, lfoSpeed: 26, pmd: 5),
        bass("Bass 1", ratio: 1, bright: 88, decay: 45, fb: 6),
        bass("Slap Bass", ratio: 3, bright: 92, decay: 55, fb: 7),
        bass("Sub Bass", ratio: 1, bright: 70, decay: 30, fb: 3, sustain: 80),
        bass("Synth Bass", ratio: 2, bright: 94, decay: 50, fb: 7, sustain: 60),
        bell("Bells", mods: [(3, 50), (7, 0), (5, 41)], decay: 32, level: 82),
        bell("Tubular", mods: [(3, 50), (3, 50), (7, 0)], decay: 28, level: 76),
        bell("Glocken", mods: [(7, 0), (11, 0), (5, 0)], decay: 40, level: 72),
        pluck("Marimba", ratio: 4, bright: 70, decay: 55, fb: 0, ratio2: 10),
        pluck("Vibes", ratio: 4, bright: 66, decay: 35, fb: 0, ratio2: 3),
        pluck("Clav", ratio: 3, bright: 92, decay: 48, fb: 6),
        pluck("Harpsichord", ratio: 5, bright: 90, decay: 40, fb: 5, ratio2: 2),
        pluck("Guitar", ratio: 2, bright: 82, decay: 38, fb: 4),
        pluck("Harp", ratio: 1, bright: 74, decay: 34, fb: 2, ratio2: 2),
        pluck("Kalimba", ratio: 6, bright: 68, decay: 46, fb: 0, ratio2: 4),
        organ("Organ 1", drawbars: [(1, 99), (2, 94), (0, 90), (3, 80), (4, 76), (6, 70)]),
        organ("Perc Organ", drawbars: [(1, 99), (2, 90), (3, 86), (4, 78), (6, 70), (8, 66)], click: true),
        organ("Reed Organ", drawbars: [(1, 99), (2, 86), (3, 84), (5, 70), (7, 64), (9, 60)], fb: 3),
        wind("Flute", ratio: 1, bright: 60, breath: 70),
        wind("Clarinet", ratio: 2, bright: 72, breath: 64, attack: 70),
        wind("Oboe", ratio: 3, bright: 78, breath: 60, attack: 75),
        lead("Saw Lead", ratio: 1, bright: 92, fb: 7, portamentoish: true),
        lead("Square Lead", ratio: 2, bright: 86, fb: 6),
    ]
}
