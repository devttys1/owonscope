import CLibUSB
import Foundation

public struct USBError: Error, CustomStringConvertible {
    public let code: Int32
    public let context: String

    public var description: String {
        let name = String(cString: libusb_error_name(code))
        return "\(context): \(name) (\(code))"
    }

    public var isTimeout: Bool { code == LIBUSB_ERROR_TIMEOUT.rawValue }
    public var isDisconnected: Bool {
        code == LIBUSB_ERROR_NO_DEVICE.rawValue || code == LIBUSB_ERROR_IO.rawValue
    }
}

/// Thin synchronous wrapper around a libusb device handle with one claimed
/// interface and a pair of bulk endpoints. Not thread safe: confine to one thread.
public final class USBDevice {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private let interface: Int32
    private var reattachKernelDriver = false
    public private(set) var endpointOut: UInt8 = 0
    public private(set) var endpointIn: UInt8 = 0

    /// Returns nil if no matching device is present.
    public init?(vendorID: UInt16, productID: UInt16, interface: Int32 = 0) throws {
        self.interface = interface
        var ctx: OpaquePointer?
        try Self.check(libusb_init(&ctx), "libusb_init")
        context = ctx

        guard let h = libusb_open_device_with_vid_pid(ctx, vendorID, productID) else {
            libusb_exit(ctx)
            context = nil
            return nil
        }
        handle = h

        do {
            try findEndpoints()
            if libusb_kernel_driver_active(h, interface) == 1 {
                try Self.check(libusb_detach_kernel_driver(h, interface), "detach_kernel_driver")
                reattachKernelDriver = true
            }
            try Self.check(libusb_claim_interface(h, interface), "claim_interface")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    private func findEndpoints() throws {
        guard let dev = libusb_get_device(handle) else {
            throw USBError(code: LIBUSB_ERROR_NO_DEVICE.rawValue, context: "get_device")
        }
        var configPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        try Self.check(libusb_get_active_config_descriptor(dev, &configPtr), "get_config_descriptor")
        defer { libusb_free_config_descriptor(configPtr) }
        guard let config = configPtr?.pointee, Int(config.bNumInterfaces) > Int(interface) else {
            throw USBError(code: LIBUSB_ERROR_NOT_FOUND.rawValue, context: "interface")
        }
        let intf = config.interface[Int(interface)]
        guard intf.num_altsetting > 0 else {
            throw USBError(code: LIBUSB_ERROR_NOT_FOUND.rawValue, context: "altsetting")
        }
        let alt = intf.altsetting[0]
        for i in 0..<Int(alt.bNumEndpoints) {
            let addr = alt.endpoint[i].bEndpointAddress
            if addr & 0x80 == 0 { endpointOut = addr } else { endpointIn = addr }
        }
        guard endpointOut != 0, endpointIn != 0 else {
            throw USBError(code: LIBUSB_ERROR_NOT_FOUND.rawValue, context: "endpoints")
        }
    }

    public func close() {
        if let h = handle {
            libusb_release_interface(h, interface)
            if reattachKernelDriver { libusb_attach_kernel_driver(h, interface) }
            libusb_close(h)
            handle = nil
        }
        if let ctx = context {
            libusb_exit(ctx)
            context = nil
        }
    }

    public var isOpen: Bool { handle != nil }

    public func bulkWrite(_ bytes: [UInt8], timeout: UInt32) throws {
        guard let h = handle else { throw USBError(code: LIBUSB_ERROR_NO_DEVICE.rawValue, context: "write") }
        var transferred: Int32 = 0
        var data = bytes
        let rc = data.withUnsafeMutableBufferPointer { buf in
            libusb_bulk_transfer(h, endpointOut, buf.baseAddress, Int32(buf.count), &transferred, timeout)
        }
        try Self.check(rc, "bulk write")
        if Int(transferred) != bytes.count {
            throw USBError(code: LIBUSB_ERROR_IO.rawValue, context: "short write \(transferred)/\(bytes.count)")
        }
    }

    /// Reads one bulk transfer into `buffer`, returning the number of bytes received.
    public func bulkRead(into buffer: UnsafeMutableBufferPointer<UInt8>, timeout: UInt32) throws -> Int {
        guard let h = handle else { throw USBError(code: LIBUSB_ERROR_NO_DEVICE.rawValue, context: "read") }
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(h, endpointIn, buffer.baseAddress, Int32(buffer.count), &transferred, timeout)
        try Self.check(rc, "bulk read")
        return Int(transferred)
    }

    public static func isPresent(vendorID: UInt16, productID: UInt16) -> Bool {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0 else { return false }
        defer { libusb_exit(ctx) }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let devices = list else { return false }
        defer { libusb_free_device_list(devices, 1) }
        for i in 0..<count {
            var desc = libusb_device_descriptor()
            if libusb_get_device_descriptor(devices[i], &desc) == 0,
               desc.idVendor == vendorID, desc.idProduct == productID {
                return true
            }
        }
        return false
    }

    private static func check(_ rc: Int32, _ context: String) throws {
        if rc < 0 { throw USBError(code: rc, context: context) }
    }
}
