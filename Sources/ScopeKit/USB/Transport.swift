import Foundation

/// A pair of bulk endpoints to the scope. On macOS this is libusb (`USBDevice`); another
/// platform can plug in its own (for example an iPadOS DriverKit user client) through
/// `ScopeTransport.open`. Implementations need not be thread safe: the driver confines
/// each one to its engine thread.
public protocol BulkTransport: AnyObject {
    func bulkWrite(_ bytes: [UInt8], timeout: UInt32) throws
    /// Reads one bulk transfer into `buffer`, returning the number of bytes received.
    func bulkRead(into buffer: UnsafeMutableBufferPointer<UInt8>, timeout: UInt32) throws -> Int
    func close()
}

/// Errors a transport throws, classified so the driver can retry or reconnect.
public protocol TransportFailure: Error {
    var isTimeout: Bool { get }
    var isDisconnected: Bool { get }
}

/// How the engine finds and opens a directly attached scope.
public enum ScopeTransport {
    /// Whether a scope is attached (cheap; polled about once a second while searching).
    nonisolated(unsafe) public static var isPresent: () -> Bool = defaultIsPresent
    /// Opens the attached scope, or returns nil if there is none.
    nonisolated(unsafe) public static var open: () throws -> BulkTransport? = defaultOpen

    /// Whether this platform can reach a scope over USB at all.
    public static var isAvailable: Bool {
        #if canImport(CLibUSB)
        return true
        #else
        return customized
        #endif
    }

    /// Set when a platform installs its own `open`/`isPresent`.
    nonisolated(unsafe) public static var customized = false

    private static func defaultIsPresent() -> Bool {
        #if canImport(CLibUSB)
        return USBDevice.isPresent(vendorID: VDS1022.vendorID, productID: VDS1022.productID)
        #else
        return false
        #endif
    }

    private static func defaultOpen() throws -> BulkTransport? {
        #if canImport(CLibUSB)
        return try USBDevice(vendorID: VDS1022.vendorID, productID: VDS1022.productID)
        #else
        return nil
        #endif
    }
}
