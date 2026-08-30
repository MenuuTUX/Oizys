import Foundation
import CoreGraphics
import ObjectiveC.runtime

// The virtual-display API is private. Keep every selector here, check availability,
// and return failure to C when an OS release removes one. No codec or USB code here.
private func method(_ object: AnyClass, _ selector: String, classMethod: Bool = false) -> IMP? {
    let name = NSSelectorFromString(selector)
    return (classMethod ? class_getClassMethod(object, name) : class_getInstanceMethod(object, name)).map(method_getImplementation)
}

private func allocate(_ name: String) -> (AnyClass, UnsafeMutableRawPointer)? {
    guard let cls = NSClassFromString(name), let implementation = method(cls, "alloc", classMethod: true) else { return nil }
    typealias Allocate = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
    guard let object = unsafeBitCast(implementation, to: Allocate.self)(cls, NSSelectorFromString("alloc")) else { return nil }
    return (cls, object)
}

private func make(_ name: String) -> NSObject? {
    guard let cls = NSClassFromString(name), let initialize = method(cls, "init"),
          let (_, raw) = allocate(name) else { return nil }
    typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
    guard let result = unsafeBitCast(initialize, to: Initialize.self)(raw, NSSelectorFromString("init")) else { return nil }
    return Unmanaged<NSObject>.fromOpaque(result).takeRetainedValue()
}

@_cdecl("mview_virtual_display_create")
func createVirtualDisplay(_ description: UnsafePointer<MViewVirtualDisplayDesc>?) -> UnsafeMutableRawPointer? {
    guard let desc = description?.pointee, desc.width > 0, desc.height > 0,
          let displayClass = NSClassFromString("CGVirtualDisplay"),
          let displayInit = method(displayClass, "initWithDescriptor:"),
          let apply = method(displayClass, "applySettings:"),
          method(displayClass, "displayID") != nil,
          let modeClass = NSClassFromString("CGVirtualDisplayMode"),
          let modeInit = method(modeClass, "initWithWidth:height:refreshRate:"),
          let descriptor = make("CGVirtualDisplayDescriptor"),
          let settings = make("CGVirtualDisplaySettings") else { return nil }
    let fields = ["name", "maxPixelsWide", "maxPixelsHigh", "sizeInMillimeters", "productID", "vendorID", "serialNum", "dispatchQueue", "terminationHandler"]
    guard fields.allSatisfy({ descriptor.responds(to: NSSelectorFromString("set\($0.prefix(1).uppercased())\($0.dropFirst()):")) }),
          settings.responds(to: NSSelectorFromString("setModes:")),
          settings.responds(to: NSSelectorFromString("setHiDPI:")) else { return nil }
    descriptor.setValue(desc.name.map(String.init(cString:)) ?? "Mview", forKey: "name")
    descriptor.setValue(desc.width, forKey: "maxPixelsWide")
    descriptor.setValue(desc.height, forKey: "maxPixelsHigh")
    descriptor.setValue(NSValue(size: NSSize(width: desc.mm_width, height: desc.mm_height)), forKey: "sizeInMillimeters")
    descriptor.setValue(desc.product_id, forKey: "productID")
    descriptor.setValue(desc.vendor_id, forKey: "vendorID")
    descriptor.setValue(desc.serial, forKey: "serialNum")
    descriptor.setValue(DispatchQueue(label: "org.mview.display"), forKey: "dispatchQueue")
    let termination: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in }
    descriptor.setValue(termination as AnyObject, forKey: "terminationHandler")
    guard let (_, modeRaw) = allocate("CGVirtualDisplayMode") else { return nil }
    typealias ModeInit = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
    guard let modeResult = unsafeBitCast(modeInit, to: ModeInit.self)(modeRaw, NSSelectorFromString("initWithWidth:height:refreshRate:"), desc.width, desc.height, desc.refresh_hz) else { return nil }
    let mode = Unmanaged<NSObject>.fromOpaque(modeResult).takeRetainedValue()
    settings.setValue([mode], forKey: "modes")
    settings.setValue(0, forKey: "hiDPI")
    guard let (_, raw) = allocate("CGVirtualDisplay") else { return nil }
    typealias DisplayInit = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    guard let result = unsafeBitCast(displayInit, to: DisplayInit.self)(raw, NSSelectorFromString("initWithDescriptor:"), Unmanaged.passUnretained(descriptor).toOpaque()) else { return nil }
    let display = Unmanaged<NSObject>.fromOpaque(result).takeRetainedValue()
    typealias Apply = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer) -> Bool
    guard unsafeBitCast(apply, to: Apply.self)(result, NSSelectorFromString("applySettings:"), Unmanaged.passUnretained(settings).toOpaque()) else { return nil }
    return Unmanaged.passRetained(display).toOpaque()
}

@_cdecl("mview_virtual_display_id")
func virtualDisplayID(_ pointer: UnsafeRawPointer?) -> UInt32 {
    guard let pointer else { return 0 }
    let display = Unmanaged<NSObject>.fromOpaque(pointer).takeUnretainedValue()
    return (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
}

@_cdecl("mview_virtual_display_destroy")
func destroyVirtualDisplay(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer { Unmanaged<NSObject>.fromOpaque(pointer).release() }
}
