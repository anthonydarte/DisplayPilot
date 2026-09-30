import Foundation
import CoreGraphics
import IOKit

/// Accès aux API privées d'Apple, résolues dynamiquement (dlsym) pour éviter
/// tout lien direct vers des frameworks privés. Si un symbole disparaît dans une
/// future version de macOS, la fonction correspondante devient simplement `nil`.
enum PrivateAPI {
    // MARK: Types C
    typealias DSGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias DSSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias ConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    typealias AVCreateFn = @convention(c) (CFAllocator?, io_service_t) -> OpaquePointer?
    typealias AVI2CFn = @convention(c) (OpaquePointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let RTLD_DEFAULT_HANDLE = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ name: String, in library: String? = nil, as _: T.Type) -> T? {
        let handle: UnsafeMutableRawPointer? = library.flatMap { dlopen($0, RTLD_LAZY) } ?? RTLD_DEFAULT_HANDLE
        guard let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    private static let displayServices =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let skyLight =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    // MARK: Luminosité écran intégré (DisplayServices)
    static let getBrightness = symbol("DisplayServicesGetBrightness", in: displayServices, as: DSGetBrightnessFn.self)
    static let setBrightness = symbol("DisplayServicesSetBrightness", in: displayServices, as: DSSetBrightnessFn.self)

    // MARK: Activer / désactiver un écran (équivalent "déconnecter" logiciel)
    static let configureDisplayEnabled: ConfigureDisplayEnabledFn? =
        symbol("SLSConfigureDisplayEnabled", in: skyLight, as: ConfigureDisplayEnabledFn.self)
        ?? symbol("CGSConfigureDisplayEnabled", as: ConfigureDisplayEnabledFn.self)

    // MARK: DDC/CI sur Apple Silicon (IOAVService, exporté par IOKit)
    static let avCreate = symbol("IOAVServiceCreateWithService", as: AVCreateFn.self)
    static let avRead = symbol("IOAVServiceReadI2C", as: AVI2CFn.self)
    static let avWrite = symbol("IOAVServiceWriteI2C", as: AVI2CFn.self)
}
