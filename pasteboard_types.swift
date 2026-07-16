import AppKit

let pb = NSPasteboard.general
if let types = pb.types {
    print(types.map { $0.rawValue })
}
