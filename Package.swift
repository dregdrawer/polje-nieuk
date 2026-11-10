// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PoljeNieuk",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PoljeNieukCore", targets: ["PoljeNieukCore"]),
        .library(name: "PoljeNieukUI", targets: ["PoljeNieukUI"]),
        .executable(name: "PoljeNieukMac", targets: ["PoljeNieukMac"]),
        .executable(name: "polje-nieuk-selftest", targets: ["SelfTest"]),
    ],
    targets: [
        // Open-source Eurorack DSP by Emilie Gillet (MIT) + a small C bridge. See Vendor/mutable.
        .target(
            name: "MutableDSP",
            path: "Vendor/mutable",
            exclude: ["README-upstream.md", "stmlib/LICENSE"],
            sources: ["clouds", "rings", "plaits", "elements", "warps", "tides2", "marbles", "stages", "braids", "beads",
                      "stmlib/dsp/units.cc", "stmlib/dsp/atan.cc", "stmlib/utils/random.cc",
                      "bridge/mi_bridge.cpp"],
            publicHeadersPath: "bridge/include",
            cxxSettings: [.define("TEST"), .headerSearchPath("."), .unsafeFlags(["-w"])]
        ),
        .target(name: "PoljeNieukCore", dependencies: ["MutableDSP"]),
        .target(name: "PoljeNieukUI", dependencies: ["PoljeNieukCore"]),
        .executableTarget(name: "PoljeNieukMac", dependencies: ["PoljeNieukUI"]),
        .executableTarget(name: "SelfTest", dependencies: ["PoljeNieukCore", "PoljeNieukUI"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .gnucxx14
)
