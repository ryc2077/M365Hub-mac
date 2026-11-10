// Seed the m365hub_admin session cookie into the shared cookie storage
// so the Mac app (URLSession.shared) sees itself as logged in and skips
// its login screen. Used by the CI memory test: synthetic keystrokes and
// coordinate clicks do not reach the app in the runner's GUI session, so
// the login screen cannot be driven through the UI at all.
// Usage: swift seed-session.swift <cookie-value>
// The app is not sandboxed, so it reads the same shared cookie storage
// this script writes.
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: seed-session.swift <cookie-value>\n", stderr)
    exit(2)
}
let value = CommandLine.arguments[1]
let props: [HTTPCookiePropertyKey: Any] = [
    .name: "m365hub_admin",
    .value: value,
    .domain: "127.0.0.1",
    .path: "/",
    .secure: false,
    // Persistent (not session-only): a cookie without an expiry was not
    // returned by cookies(for:) in this context.
    .expires: Date(timeIntervalSinceNow: 12 * 3600),
]
guard let cookie = HTTPCookie(properties: props) else {
    fputs("failed to create cookie\n", stderr)
    exit(1)
}
print("created cookie: name=\(cookie.name) domain=\(cookie.domain) path=\(cookie.path) expires=\(String(describing: cookie.expiresDate)) isSessionOnly=\(cookie.isSessionOnly)")
HTTPCookieStorage.shared.setCookie(cookie)
// Give the shared store a moment to persist before the app reads it.
Thread.sleep(forTimeInterval: 1)
let all = HTTPCookieStorage.shared.cookies ?? []
print("all cookies in shared store: \(all.map { "\($0.name)@\($0.domain)\($0.path)" })")
if all.contains(where: { $0.name == "m365hub_admin" && $0.domain == "127.0.0.1" }) {
    print("cookie seeded: m365hub_admin present for 127.0.0.1")
} else {
    fputs("cookie NOT stored\n", stderr)
    exit(1)
}
