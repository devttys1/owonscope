import Foundation

/// Translates declarative `ScopeSettings` into the ordered list of register writes
/// the VDS1022 needs. The engine diffs successive maps and only sends changes.
public enum RegisterMap {
    public typealias Write = (command: VDS1022.Command, value: UInt32)

    /// - Parameters:
    ///   - freqRefCounts: frequency-meter threshold (ADC counts) for channels that are
    ///     not the trigger source. nil uses the channel's 0 V level.
    public static func writes(for s: ScopeSettings, flash: VDS1022Flash, fpgaVersion: Int,
                              freqRefCounts: [Int?] = [nil, nil]) -> [Write] {
        typealias C = VDS1022.Cmd
        var w: [Write] = []
        let tb = s.timebase
        let roll = tb.isRollMode

        w.append((C.setChannelsOn, 0))
        w.append((C.setPhaseFine, UInt32(flash.phaseFine)))
        w.append((C.setTimebase, tb.prescaler))
        w.append((C.setRollMode, roll ? 1 : 0))
        w.append((C.setPeakMode, s.peakDetect ? 1 : 0))
        // +3 fixes bad trailing samples in roll mode.
        w.append((C.setDeepMemory, UInt32(VDS1022.adcSize + (roll ? 3 : 0))))

        for ch in 0..<VDS1022.channelCount {
            let c = s.channels[ch]
            let vb = c.rangeIndex
            let comp = Double(flash.cal(.compensation, channel: ch, range: vb))
            let ampl = Double(flash.cal(.amplitude, channel: ch, range: vb))
            let gain = flash.cal(.gain, channel: ch, range: vb)
            let pos0 = c.zeroCounts
            let zero = clamp(Int((comp - pos0 * ampl / 100).rounded()), 0, 4095)
            w.append((C.setZeroOffset[ch], UInt32(zero)))
            w.append((C.setVoltGain[ch], UInt32(clamp(gain, 0, 4095))))
            // b1: attenuation relay, b5-6: coupling, b7: on
            let attenuate: UInt32 = vb >= VDS1022.attenuationThreshold ? 1 : 0
            let reg = attenuate << 1 | c.coupling.register << 5 | (c.enabled ? 1 : 0) << 7
            w.append((C.setChannel[ch], reg))
        }

        let t = s.trigger
        w.append((C.setMulti, t.source == .ext ? 2 : 0))

        // Samples before/after the trigger: position 0 => 50/5050, 0.5 => 2550/2550.
        let position = roll ? 1.0 : s.triggerPosition
        let htp = Int((Double(VDS1022.samplesPerFrame) * clamp(0.5 - position, -0.5, 0.5)).rounded())
        let half = VDS1022.adcSize >> 1
        w.append((C.setPreTrigger, UInt32(half - htp - VDS1022.htpError)))
        w.append((C.setPostTrigger, UInt32(half + htp + VDS1022.htpError)))

        for ch in 0..<VDS1022.channelCount {
            let c = s.channels[ch]
            if t.source.channel == ch {
                let fall = t.slope == .falling
                let lvl = Int(c.counts(volts: t.level).rounded()) + (fall ? 10 : 0)
                let v = clamp(lvl, VDS1022.adcMin + 10, VDS1022.adcMax)
                w.append((C.setEdgeLevel[ch], VDS1022.u16(v, v - 10)))
                w.append((C.setFreqRef[ch], UInt32((v - 5) & 0xff)))
                w.append((C.setTriggerHoldoff[ch], VDS1022.holdoffRegister(seconds: t.holdoff)))
                if t.mode == .pulse { w += pulseWidthWrites(t, channel: ch, fpgaVersion: fpgaVersion) }
            } else {
                let ref = freqRefCounts[ch] ?? Int(c.zeroCounts.rounded()) + 12
                w.append((C.setEdgeLevel[ch], VDS1022.u16(127, -128))) // disabled
                w.append((C.setFreqRef[ch], UInt32(clamp(ref, -120, 120) & 0xff)))
                let holdoff = (t.source == .ext && ch == 0) ? t.holdoff : 100e-9
                w.append((C.setTriggerHoldoff[ch], VDS1022.holdoffRegister(seconds: holdoff)))
            }
        }

        w.append((C.setTrigger, triggerWord(t)))
        return w
    }

    /// Single (non-alternate) trigger control word.
    public static func triggerWord(_ t: TriggerSettings) -> UInt32 {
        // bit 0: external source, bit 13: CH2, bits 10-11: sweep
        var trg: UInt32 = t.source == .ext ? 1 : 0
        if t.source == .ch2 { trg |= 1 << 13 }
        trg |= t.sweep.register << 10
        if t.mode == .pulse && t.source != .ext {
            // mode 3 (pulse) is encoded in bits 8 and 14; condition in bits 5-7
            trg |= 1 << 8 | 1 << 14
            trg |= pulseConditionCode(t) << 5
        } else if t.slope == .falling {
            trg |= 1 << 12 // edge: falling
        }
        return trg
    }

    /// 0: +width >, 1: +width =, 2: +width <, 3: -width >, 4: -width =, 5: -width <
    static func pulseConditionCode(_ t: TriggerSettings) -> UInt32 {
        let base: UInt32 = t.slope == .rising ? 0 : 3
        switch t.pulseCondition {
        case .greater: return base
        case .equal: return base + 1
        case .less: return base + 2
        }
    }

    /// Pulse width registers (units of 10 ns).
    static func pulseWidthWrites(_ t: TriggerSettings, channel ch: Int, fpgaVersion: Int) -> [Write] {
        typealias C = VDS1022.Cmd
        let tens = max(1, t.pulseWidth * 1e8)
        if fpgaVersion >= 3 {
            let m = UInt32(min(tens, Double(UInt32.max)))
            return [(C.setTriggerCdtGL[ch], m % 65536), (C.setTriggerCdtHL[ch], m / 65536)]
        }
        // Older FPGAs: 10 bit mantissa + base-10 exponent
        let (m, e) = VDS1022.mantissaExponent(tens, limit: 1023)
        if t.pulseCondition == .equal {
            return [(C.setTriggerCdtEquH[ch], UInt32(Double(m) * 1.05) << 6 | e & 7),
                    (C.setTriggerCdtEquL[ch], UInt32(Double(m) * 0.95))]
        }
        return [(C.setTriggerCdtGL[ch], m), (C.setTriggerCdtEquH[ch], e)]
    }

    static func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { min(max(x, lo), hi) }
}
