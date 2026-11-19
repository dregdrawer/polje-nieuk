#pragma once
#include "Engine.h"

namespace pn {

/// Name tables shared by the registry and the modules (the Swift enums of the same names).
struct Layouts {
    static const std::vector<std::string> gridNames, scaleNames, macroEngines, shapesNames,
                                          chanceModels, chanceScales, chanceLengths, drumVoices;
    static const std::vector<int> drumEngines;
    static std::vector<std::string> dividerRatioNames();
    static int dividerRatioIndex(int ratio);
};

/// The DSP for `kind`, or null while that module isn't ported to this version yet.
Factory factoryFor(const std::string& kind);

template <class T> Factory make() {
    return [](const ModuleSpec& s, double sr) -> std::unique_ptr<DSPNode> { return std::make_unique<T>(s, sr); };
}

// per-file factory lookups (each returns null for kinds it doesn't have)
Factory factoryCore(const std::string& kind);
Factory factoryMI(const std::string& kind);
Factory factoryFX(const std::string& kind);
Factory factoryFX2(const std::string& kind);
Factory factoryBuffers(const std::string& kind);
Factory factorySeq(const std::string& kind);
Factory factoryInst(const std::string& kind);

} // namespace pn
