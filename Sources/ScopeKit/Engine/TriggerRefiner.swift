import Foundation

/// Re-aligns an acquisition on the exact (sub-sample) trigger level crossing.
///
/// The VDS1022 trigger point lands a few samples off depending on the sample rate
/// (about -11 samples at 100 MS/s, +3 at 10 MS/s) and jitters by one sample. Snapping
/// to the interpolated crossing gives a stable, jitter-free display at fast timebases.
public enum TriggerRefiner {
    public static func refine(_ acq: inout Acquisition, searchSamples: Int = 40) {
        let s = acq.settings
        guard acq.triggerState == .triggered, let ch = s.trigger.source.channel,
              let w = acq.channel(ch), w.count > 2 else { return }
        let level = Float(s.trigger.level)
        // A pulse-width trigger fires on the trailing edge of the qualifying pulse.
        let rising = (s.trigger.slope == .rising) != (s.trigger.mode == .pulse)
        let center = w.index(at: 0)
        var best: Double?
        let lo = max(1, center - searchSamples), hi = min(w.count - 1, center + searchSamples)
        guard lo < hi else { return }
        for i in lo...hi {
            let a = w.volts[i - 1], b = w.volts[i]
            let crosses = rising ? (a < level && b >= level) : (a > level && b <= level)
            guard crosses else { continue }
            let pos = Double(i - 1) + Double((level - a) / (b - a))
            if best == nil || abs(pos - Double(center)) < abs(best! - Double(center)) { best = pos }
        }
        guard let pos = best else { return }
        let shift = w.t0 + pos * w.dt // time of the crossing in the current frame
        for k in acq.channels.indices where acq.channels[k] != nil {
            acq.channels[k]!.t0 -= shift
        }
    }
}
