import Foundation

/// Finds the vendor FPGA bitstream (`VDS1022_FPGAV<n>_*.bin`).
///
/// The bitstreams are OWON's binaries, so they are not shipped in this repository.
/// They are looked up, in order, in:
///  1. `$OWON_FIRMWARE_DIR`
///  2. `~/Library/Application Support/OwonScope/Firmware`
///  3. the app bundle's `Resources/Firmware`
///  4. an installed florentbr "OWON VDS1022.app"
public enum FirmwareLocator {
    public static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OwonScope/Firmware", isDirectory: true)
    }

    public static var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["OWON_FIRMWARE_DIR"] {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        dirs.append(userDirectory)
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("Firmware", isDirectory: true))
        }
        dirs.append(URL(fileURLWithPath: "/Applications/OWON VDS1022.app/Contents/Resources/fwr", isDirectory: true))
        return dirs
    }

    public static func find(fpgaVersion: Int) -> URL? {
        let prefix = "VDS1022_FPGAV\(fpgaVersion)_"
        for dir in searchDirectories {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            if let name = items.filter({ $0.hasPrefix(prefix) && $0.lowercased().hasSuffix(".bin") }).sorted().last {
                return dir.appendingPathComponent(name)
            }
        }
        return nil
    }

    /// Copies all `VDS1022_FPGAV*.bin` files from `folder` into the user firmware directory.
    @discardableResult
    public static func importFirmware(from folder: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        var count = 0
        for name in try fm.contentsOfDirectory(atPath: folder.path)
        where name.hasPrefix("VDS1022_FPGAV") && name.lowercased().hasSuffix(".bin") {
            let dst = userDirectory.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: folder.appendingPathComponent(name), to: dst)
            count += 1
        }
        return count
    }
}
