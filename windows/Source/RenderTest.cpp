// pnrender <patch.json> <seconds>: renders a patch offline (no input) and prints every outlet's RMS.
// The Mac app's selftest has the same mode (--render), so the two engines can be compared number for number.
#include "Engine.h"
#include <cstdio>

int main(int argc, char** argv) {
    juce::ScopedJuceInitialiser_GUI init;
    if (argc < 3) { std::printf("usage: pnrender patch.json seconds\n"); return 1; }
    auto json = juce::File(juce::String::fromUTF8(argv[1])).loadFileAsString();
    auto parsed = pn::Patch::fromJSON(json);
    if (!parsed) { std::printf("can't read patch\n"); return 1; }
    auto p = parsed->migrated();
    double seconds = std::atof(argv[2]);
    pn::GraphHost h(48000);
    h.load(p);
    const int block = 256, chans = 8;
    std::vector<std::vector<float>> ins(chans, std::vector<float>(block, 0.0f)), outs(chans, std::vector<float>(block, 0.0f));
    std::vector<const float*> ip; std::vector<float*> op;
    for (auto& b : ins) ip.push_back(b.data());
    for (auto& b : outs) op.push_back(b.data());
    std::vector<std::vector<double>> sums;
    for (auto& n : p.nodes) { auto* d = h.node(n.id); sums.emplace_back(d ? d->outputs.size() : 0, 0.0); }
    int blocks = int(seconds * 48000) / block, total = 0;
    for (int b = 0; b < blocks; ++b) {
        for (auto& o : outs) std::fill(o.begin(), o.end(), 0.0f);
        h.process(block, ip.data(), chans, op.data(), chans);
        for (size_t i = 0; i < p.nodes.size(); ++i)
            if (auto* d = h.node(p.nodes[i].id))
                for (size_t k = 0; k < d->outputs.size(); ++k)
                    for (int s = 0; s < 64; ++s) { double v = d->outputs[k][size_t(s)]; sums[i][k] += v * v; }
        total += 64;
    }
    for (size_t i = 0; i < p.nodes.size(); ++i) {
        std::printf("%d %s", int(i), p.nodes[i].kind.c_str());
        for (double s : sums[i]) std::printf(" %.4f", std::sqrt(s / std::max(total, 1)));
        std::printf("\n");
    }
    return 0;
}
