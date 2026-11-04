import Foundation
import IOKit

enum TouchBar {
    static let isPresent: Bool = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDUserDevice"),
                                           &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let product = IORegistryEntryCreateCFProperty(
                service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               product == "TouchBarUserDevice" {
                return true
            }
        }
        return false
    }()
}
