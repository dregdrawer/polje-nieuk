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
        // A small VST3 host (our code) over Steinberg's VST3 interface headers (MIT). See Vendor/vst3.
        .target(
            name: "PluginBridge",
            path: "Vendor/vst3",
            exclude: ["pluginterfaces/LICENSE.txt", "pluginterfaces/README.md"],
            sources: ["bridge/vst3host.cpp", "pluginterfaces/base/funknown.cpp"],
            publicHeadersPath: "bridge/include",
            cxxSettings: [.headerSearchPath("."), .unsafeFlags(["-w"])],
            linkerSettings: [.linkedFramework("CoreFoundation")]
        ),
        // the audio engine: no runtime exclusivity checks on every per-sample access to a module's stored arrays
        // (only the audio thread touches them while it runs). Release builds are whole-module optimised.
        .target(name: "PoljeNieukCore", dependencies: ["MutableDSP", "PluginBridge"],
                swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])]),
        .target(name: "PoljeNieukUI", dependencies: ["PoljeNieukCore"]),
        .executableTarget(name: "PoljeNieukMac", dependencies: ["PoljeNieukUI"]),
        .executableTarget(name: "SelfTest", dependencies: ["PoljeNieukCore", "PoljeNieukUI"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .gnucxx14
)
