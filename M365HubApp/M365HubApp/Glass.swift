import SwiftUI

// Native liquid glass for the pills (input bar, nav items).
// macOS 26+ has the real thing: SwiftUI's .glassEffect() is Apple's own
// Liquid Glass material (refraction, specular, morphing) — this is the
// iOS-style glass the web SVG filter was only approximating. On older
// macOS the same views fall back to ultraThinMaterial so the app still
// runs and still looks like glass, just without refraction.
//
// NOTE: the gate must be `#if compiler(>=6.2)` (Xcode 26 SDK), NOT just
// `#available(macOS 26.0, *)`. #available is a *runtime* check, but an
// older SDK does not contain the glassEffect symbol at all, so merely
// mentioning it fails the build on Xcode < 26 ("has no member
// 'glassEffect'"). Swift 6.2 ships with Xcode 26; older Xcode compiles
// the fallback branch only. Use `compiler`, not `swift`, because the
// project sets SWIFT_VERSION = 5.0, which would make a `swift(>=6.2)`
// check false even under Xcode 26.
#if compiler(>=6.2)
extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 999) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}
#else
extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 999) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func liquidGlassCircle() -> some View {
        self.background(.ultraThinMaterial, in: Circle())
    }
}
#endif
