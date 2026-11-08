// swift-tools-version:5.9
// The native app: a shared core, and a thin layer per OS. Each layer builds only on its
// own OS, so the manifest lists it only there. See roadmaps/05-os-core-split.md.
//
//   core      DeskBuddyCore   Foundation only
//   macos     DeskBuddyMac    AppKit, built by macos/build.sh
//   windows   DeskBuddyWin    Win32 through WinSDK, built by windows/build.ps1
import PackageDescription

var targets: [Target] = [
    .target(name: "DeskBuddyCore", path: "core", exclude: ["assets", "README.md"]),
    .testTarget(name: "DeskBuddyCoreTests", dependencies: ["DeskBuddyCore"], path: "tests"),
]
var products: [Product] = [.library(name: "DeskBuddyCore", targets: ["DeskBuddyCore"])]

#if os(macOS)
targets.append(.executableTarget(name: "DeskBuddyMac", dependencies: ["DeskBuddyCore"], path: "macos",
                                 exclude: ["Info.plist", "build.sh", "archive"]))
products.append(.executable(name: "DeskBuddy", targets: ["DeskBuddyMac"]))
#elseif os(Windows)
targets.append(.target(name: "CGdiPlus", path: "windows/gdiplus",
                       linkerSettings: [.linkedLibrary("gdiplus")]))
targets.append(.executableTarget(name: "DeskBuddyWin", dependencies: ["DeskBuddyCore", "CGdiPlus"], path: "windows/app",
                                 linkerSettings: [.linkedLibrary("user32"), .linkedLibrary("gdi32"), .linkedLibrary("shell32"),
                                                  .linkedLibrary("ole32"),
                                                  .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]))
products.append(.executable(name: "DeskBuddy", targets: ["DeskBuddyWin"]))
#endif

let package = Package(
    name: "DeskBuddy",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
