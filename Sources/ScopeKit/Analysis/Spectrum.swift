import Accelerate
import Foundation

public enum FFTWindow: String, CaseIterable, Codable, Sendable {
    case rectangular = "Rectangular", hann = "Hann", blackman = "Blackman", flatTop = "Flat top"
}

public struct Spectrum: Sendable {
    /// Magnitude in dBV (RMS) per bin.
    public var dbv: [Float]
    public var binWidth: Double
    public var peakFrequency: Double?
    public var peakDBV: Float?

    public var maxFrequency: Double { binWidth * Double(dbv.count) }
}

public enum SpectrumAnalyzer {
    /// Real FFT of up to 4096 samples (centred), windowed and scaled to dBV RMS.
    public static func compute(_ w: ChannelWaveform, window: FFTWindow) -> Spectrum? {
        let count = w.volts.count
        guard count >= 64 else { return nil }
        let log2n = vDSP_Length(min(12, Int(log2(Double(count)))))
        let n = 1 << Int(log2n)
        let trim = (count - n) / 2
        var x = Array(w.volts[trim..<(trim + n)])

        // remove DC so it doesn't dominate the plot
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(n))

        var win = [Float](repeating: 1, count: n)
        switch window {
        case .rectangular: break
        case .hann: vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        case .blackman: vDSP_blkman_window(&win, vDSP_Length(n), 0)
        case .flatTop:
            for i in 0..<n {
                let z = 2 * Double.pi * Double(i) / Double(n - 1)
                win[i] = Float(0.21557895 - 0.41663158 * cos(z) + 0.277263158 * cos(2 * z) - 0.083578947 * cos(3 * z) + 0.006947368 * cos(4 * z))
            }
        }
        var gain: Float = 0
        vDSP_meanv(win, 1, &gain, vDSP_Length(n))
        vDSP_vmul(x, 1, win, 1, &x, 1, vDSP_Length(n))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // packed Nyquist term
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // vDSP's forward real FFT is scaled by 2. Amplitude = |X| / (n * gain); RMS = amp / sqrt 2.
        var scale = Float(1.0 / (Double(n) * Double(gain) * sqrt(2.0)))
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))
        var floor: Float = 1e-7
        vDSP_vthr(mags, 1, &floor, &mags, 1, vDSP_Length(half))
        var one: Float = 1
        var db = [Float](repeating: 0, count: half)
        vDSP_vdbcon(mags, 1, &one, &db, 1, vDSP_Length(half), 1)

        let binWidth = 1 / (Double(n) * w.dt)
        var peakIdx: vDSP_Length = 0
        var peak: Float = 0
        if half > 2 {
            db.withUnsafeBufferPointer { p in
                vDSP_maxvi(p.baseAddress! + 1, 1, &peak, &peakIdx, vDSP_Length(half - 1))
            }
            peakIdx += 1
        }
        // Quadratic interpolation of the peak over its neighbours (in dB) for sub-bin accuracy.
        var peakFreq: Double? = nil
        if half > 2 {
            let i = Int(peakIdx)
            var offset = 0.0
            if i > 0 && i < half - 1 {
                let a = Double(db[i - 1]), b = Double(db[i]), c = Double(db[i + 1])
                let denom = a - 2 * b + c
                if denom != 0 { offset = max(-0.5, min(0.5, 0.5 * (a - c) / denom)) }
            }
            peakFreq = (Double(i) + offset) * binWidth
        }
        return Spectrum(dbv: db, binWidth: binWidth, peakFrequency: peakFreq, peakDBV: half > 2 ? peak : nil)
    }
}

public enum Interpolator {
    /// Windowed sin(x)/x reconstruction of `w` over [start, end] with `points` output samples.
    public static func sinc(_ w: ChannelWaveform, from start: Double, to end: Double, points: Int, taps: Int = 8) -> [Float] {
        sinc(values: w.volts, t0: w.t0, dt: w.dt, from: start, to: end, points: points, taps: taps)
    }

    public static func sinc(values v: [Float], t0: Double, dt: Double, from start: Double, to end: Double, points: Int, taps: Int = 8) -> [Float] {
        guard points > 1, v.count > 1 else { return [] }
        var out = [Float](repeating: 0, count: points)
        let step = (end - start) / Double(points - 1)
        for k in 0..<points {
            let x = (start + Double(k) * step - t0) / dt
            let i0 = Int(floor(x))
            var acc = 0.0, norm = 0.0
            for i in (i0 - taps + 1)...(i0 + taps) where i >= 0 && i < v.count {
                let d = x - Double(i)
                let s = d == 0 ? 1 : sin(.pi * d) / (.pi * d)
                let win = 0.5 + 0.5 * cos(.pi * d / Double(taps)) // Hann window
                let c = s * win
                acc += Double(v[i]) * c
                norm += c
            }
            out[k] = Float(norm != 0 ? acc / norm : 0)
        }
        return out
    }
}
