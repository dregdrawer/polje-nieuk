// Effects — port of Effects.swift (filter~, delay~, drive~, reverb~).
#include "Modules.h"

namespace pn {

constexpr double kPi = juce::MathConstants<double>::pi;

struct DelayLine {
    std::vector<float> buf; int w = 0;
    explicit DelayLine(int samples = 4) : buf(size_t(std::max(samples, 4)), 0.0f) {}
    int len() const { return int(buf.size()); }
    void write(float x) { buf[size_t(w)] = x; if (++w >= len()) w = 0; }
    float read(double d) const {
        double p = double(w - 1) - d;
        if (p < 0) p += len();
        if (p < 0) p = 0;
        return readLinear(buf.data(), len(), p);
    }
};

class FilterNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        int mode = clampIndex(params[0], 4), algo = clampIndex(params[4], 3);
        double target = params[1], res = std::clamp(params[2], 0.0f, 1.0f), amt = params[3];
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0]; const float* cv = in[2];
        bool hasCV = isConnected(con, 2);
        double smooth = 1 - std::exp(-1 / (0.005 * sampleRate)), nyq = sampleRate * 0.45;
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            fc += (target - fc) * smooth;
            double f = fc;
            if (hasCV) f *= std::exp2(double(cv[i]) * 10 * amt);
            f = std::clamp(f, 10.0, nyq);
            if (algo == 1) {
                float g = float(1 - std::exp(-2 * kPi * f / sampleRate)), k = float(res * 4.1);
                for (int c = 0; c < 2; ++c) {
                    float x0 = c == 0 ? inL[i] : inR[i];
                    float* L = lad + c * 4;
                    float x = std::tanh(x0 * 1.2f - k * L[3]);
                    L[0] += g * (x - L[0]); L[1] += g * (L[0] - L[1]); L[2] += g * (L[1] - L[2]); L[3] += g * (L[2] - L[3]);
                    float comp = 1 + k * 0.35f, lp = L[3] * comp, bp = (L[1] - L[3]) * 2 * comp, y;
                    switch (mode) { case 0: y = lp; break; case 1: y = bp; break; case 2: y = x - L[3]; break; default: y = x - bp; }
                    (c == 0 ? oL : oR)[i] = y;
                }
            } else {
                double g = std::tan(kPi * f / sampleRate);
                double k = algo == 2 ? 2 - 2.05 * res : 2 - 1.97 * res;
                double a1 = 1 / (1 + g * (g + std::max(k, 0.02))), a2 = g * a1, a3 = g * a2;
                for (int c = 0; c < 2; ++c) {
                    double v0 = double(c == 0 ? inL[i] : inR[i]) * (algo == 2 ? 1.5 : 1);
                    double v3 = v0 - ic2[c], v1 = a1 * ic1[c] + a2 * v3, v2 = ic2[c] + a2 * ic1[c] + a3 * v3;
                    if (algo == 2) { ic1[c] = 2 * std::tanh(v1) - ic1[c]; ic2[c] = 2 * std::tanh(v2 * 0.8) / 0.8 - ic2[c]; }
                    else { ic1[c] = 2 * v1 - ic1[c]; ic2[c] = 2 * v2 - ic2[c]; }
                    double y;
                    switch (mode) { case 0: y = v2; break; case 1: y = v1; break; case 2: y = v0 - k * v1 - v2; break; default: y = v0 - k * v1; }
                    if (algo == 2) y = softClip(float(y / 1.5));
                    (c == 0 ? oL : oR)[i] = float(y);
                }
            }
        }
        for (int c = 0; c < 2; ++c) if (!std::isfinite(ic1[c]) || !std::isfinite(ic2[c])) { ic1[c] = 0; ic2[c] = 0; }
        for (float& v : lad) if (!std::isfinite(v)) v = 0;
    }
private:
    double ic1[2] {}, ic2[2] {}, fc = 1000; float lad[8] {};
};

class DelayNode : public DSPNode {
public:
    DelayNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), len(int(sr * 10)), bufL(size_t(len), 0.0f), bufR(size_t(len), 0.0f) {}
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        bool sync = params[0] > 0.5f;
        double raw = sync ? ctx.samplesPerBeat * Divisions::beats(params[1]) : double(params[2]) * sampleRate / 1000;
        double target = std::clamp(raw, 2.0, double(len - 4) * 0.98);
        if (dtime < 0) dtime = target;
        float fb = params[3];
        int algo = clampIndex(params[7], 3);
        double tone = params[4];
        if (algo == 1) tone = std::min(tone, 7000.0);
        if (algo == 2) { double ms = dtime / sampleRate * 1000; tone = std::min(tone, std::max(700.0, 4500 * std::sqrt(120 / std::max(ms, 1.0)))); }
        float toneC = float(1 - std::exp(-2 * kPi * tone / sampleRate));
        float hpC = float(1 - std::exp(-2 * kPi * (algo == 1 ? 140 : 25) / sampleRate));
        bool pp = params[5] > 0.5f;
        float mix = params[6];
        double smooth = 1 - std::exp(-1 / (0.08 * sampleRate)), flen = len, tau = 2 * kPi / sampleRate;
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            dtime += (target - dtime) * smooth;
            double d = dtime;
            if (algo == 1) {
                wow += 0.55 * tau; flutter += 6.8 * tau;
                if ((i & 63) == 0) { wander += (rng.next() - 0.5f) * 0.02f; wander *= 0.995f; }
                d *= 1 + 0.0022 * std::sin(wow) + 0.0006 * std::sin(flutter) + double(wander) * 0.002;
            } else if (algo == 2) { drift += 0.3 * tau; d *= 1 + 0.0012 * std::sin(drift); }
            d = std::clamp(d, 2.0, flen - 4);
            double rp = double(w) - d; if (rp < 0) rp += flen;
            float dl = readLinear(bufL.data(), len, rp), dr = readLinear(bufR.data(), len, rp);
            lpL += (dl - lpL) * toneC; lpR += (dr - lpR) * toneC;
            hpL += (lpL - hpL) * hpC; hpR += (lpR - hpR) * hpC;
            float fl = lpL - hpL, fr = lpR - hpR, l = inL[i], r = inR[i], wl, wr;
            if (pp) { wl = (l + r) * 0.5f + fr * fb; wr = fl * fb; } else { wl = l + fl * fb; wr = r + fr * fb; }
            if (algo == 1) { wl = std::tanh(wl * 1.3f) / 1.3f; wr = std::tanh(wr * 1.3f) / 1.3f; }
            else if (algo == 2) { wl = softClip(wl * 1.1f); wr = softClip(wr * 1.1f); }
            else { wl = softClip(wl); wr = softClip(wr); }
            bufL[size_t(w)] = wl; bufR[size_t(w)] = wr;
            if (++w >= len) w = 0;
            oL[i] = l * (1 - mix) + dl * mix; oR[i] = r * (1 - mix) + dr * mix;
        }
        if (wow > 2 * kPi) wow -= 2 * kPi;
        if (flutter > 2 * kPi) flutter -= 2 * kPi;
        if (drift > 2 * kPi) drift -= 2 * kPi;
        readouts[0] = float(dtime / sampleRate * 1000);
    }
private:
    int len; std::vector<float> bufL, bufR; int w = 0; double dtime = -1;
    float lpL = 0, lpR = 0, hpL = 0, hpR = 0, wander = 0; double wow = 0, flutter = 0, drift = 0; XorShift rng { 0xDE1A7E99u };
};

class DriveNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    static float shape(int a, float x) {
        switch (a) {
            case 1: return std::tanh(x + 0.25f) - std::tanh(0.25f);
            case 2: return std::clamp(x, -1.0f, 1.0f);
            case 3: return std::sin(x * juce::MathConstants<float>::pi / 2);
            case 4: return x > 0 ? 1 - std::exp(-x * 1.5f) : -0.8f * (1 - std::exp(x * 2.5f));
            case 5: return std::tanh(std::abs(x) * 1.5f) * 2 - 1;
            default: return std::tanh(x);
        }
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        float g = dbToGain(params[0]), tc = float(1 - std::exp(-2 * kPi * double(params[1]) / sampleRate));
        float mix = params[2], outG = dbToGain(params[3]);
        int algo = clampIndex(params[4], 6);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        for (int i = 0; i < frames; ++i)
            for (int c = 0; c < 2; ++c) {
                float x = c == 0 ? inL[i] : inR[i], y = shape(algo, x * g);
                float d = y - dcX[c] + 0.9975f * dcY[c]; dcX[c] = y; dcY[c] = d; y = d;
                lp[c] += (y - lp[c]) * tc;
                out(c)[i] = (x * (1 - mix) + lp[c] * mix) * outG;
            }
    }
private:
    float lp[2] {}, dcX[2] {}, dcY[2] {};
};

struct Comb {
    std::vector<float> buf; int idx = 0; float store = 0;
    explicit Comb(int n = 1) : buf(size_t(std::max(n, 1)), 0.0f) {}
    float process(float x, float fb, float d1, float d2) {
        float y = buf[size_t(idx)];
        store = y * d2 + store * d1;
        buf[size_t(idx)] = x + store * fb;
        if (++idx >= int(buf.size())) idx = 0;
        return y;
    }
};
struct Allpass {
    std::vector<float> buf; int idx = 0;
    explicit Allpass(int n = 1) : buf(size_t(std::max(n, 1)), 0.0f) {}
    float process(float x) {
        float b = buf[size_t(idx)];
        buf[size_t(idx)] = x + b * 0.5f;
        if (++idx >= int(buf.size())) idx = 0;
        return b - x;
    }
};
struct APLine {
    DelayLine line; int n;
    explicit APLine(int nn = 2, int extra = 0) : line(std::max(nn, 2) + extra + 4), n(std::max(nn, 2)) {}
    float process(float x, float g, double mod = 0) {
        float d = line.read(double(n - 1) + mod), w = x + g * d;
        line.write(w);
        return d - g * w;
    }
    float tap(int k) const { return line.read(double(std::min(k, n - 1))); }
};

class ReverbNode : public DSPNode {
public:
    ReverbNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        double sc44 = sr / 44100;
        const int combT[] = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 }, apT[] = { 556, 441, 341, 225 };
        for (int t : combT) { combL.emplace_back(int(t * sc44)); combR.emplace_back(int((t + 23) * sc44)); }
        for (int t : apT) { apL.emplace_back(int(t * sc44)); apR.emplace_back(int((t + 23) * sc44)); }
        pScale = sr / 29761;
        auto sc = [&](int v) { return int(v * pScale); };
        for (int v : { 142, 107, 379, 277 }) pIn.emplace_back(sc(v));
        pApMod1 = APLine(sc(672), sc(32)); pApMod2 = APLine(sc(908), sc(32)); pAp5 = APLine(sc(1800)); pAp6 = APLine(sc(2656));
        pLen = { sc(4453), sc(3720), sc(4217), sc(3163) };
        pD[0] = DelayLine(pLen[0] + 4); pD[1] = DelayLine(pLen[1] + 4); pD[2] = DelayLine(pLen[2] + 4); pD[3] = DelayLine(pLen[3] + 4);
        for (int v : { 266, 2974, 1913, 1996, 1990, 187, 1066, 353, 3627, 1228, 2673, 2111, 335, 121 }) pTaps.push_back(sc(v));
        pSide = { APLine(sc(131)), APLine(sc(353)) };
        for (double ms : { 31.7, 37.3, 41.9, 47.3, 53.9, 61.1, 67.9, 73.7 }) {
            int l = int(ms * 1.35 * sr / 1000);
            hLen.push_back(l); hLines.emplace_back(l + int(0.004 * sr) + 8);
        }
        hDiff = { APLine(int(0.0047 * sr)), APLine(int(0.0113 * sr)), APLine(int(0.0171 * sr)) };
        hSide = { APLine(int(0.0061 * sr)), APLine(int(0.0137 * sr)) };
        sLen = { int(0.0371 * sr), int(0.0503 * sr) };
        sLines = { DelayLine(sLen[0] + 8), DelayLine(sLen[1] + 8) };
        sAP.assign(2 * springStages * 2, 0.0f);
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        int algo = clampIndex(params[5], 4);
        bool frozen = params[4] > 0.5f;
        float size = std::clamp(params[0], 0.0f, 1.0f), damp = std::clamp(params[1], 0.0f, 1.0f), mix = params[3], width = params[2];
        float dry = 1 - mix;
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        if (algo == 1) { plate(frames, inL, inR, oL, oR, size, damp, frozen, mix, width, dry); return; }
        if (algo == 2) { hall(frames, inL, inR, oL, oR, size, damp, frozen, mix, width, dry); return; }
        if (algo == 3) { spring(frames, inL, inR, oL, oR, size, damp, frozen, mix, width, dry); return; }
        float fb = frozen ? 1 : size * 0.28f + 0.7f, dmp = frozen ? 0 : damp * 0.4f, d1 = dmp, d2 = 1 - dmp;
        float gainIn = frozen ? 0 : 0.015f, wet = mix * 1.5f, wet1 = wet * (width / 2 + 0.5f), wet2 = wet * ((1 - width) / 2);
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            float xL = (l * 0.72f + r * 0.28f) * 2 * gainIn, xR = (r * 0.72f + l * 0.28f) * 2 * gainIn, sL = 0, sR = 0;
            for (int c = 0; c < 8; ++c) { sL += combL[size_t(c)].process(xL, fb, d1, d2); sR += combR[size_t(c)].process(xR, fb, d1, d2); }
            for (int a = 0; a < 4; ++a) { sL = apL[size_t(a)].process(sL); sR = apR[size_t(a)].process(sR); }
            oL[i] = sL * wet1 + sR * wet2 + l * dry; oR[i] = sR * wet1 + sL * wet2 + r * dry;
        }
    }
private:
    static constexpr int springStages = 18;
    std::vector<Comb> combL, combR; std::vector<Allpass> apL, apR;
    std::vector<APLine> pIn, pSide; APLine pApMod1, pApMod2, pAp5, pAp6; DelayLine pD[4];
    std::vector<int> pLen, pTaps; float pBW = 0, pDampL = 0, pDampR = 0, pFeedL = 0, pFeedR = 0; double pLfo = 0, pScale = 1;
    float balEnvL = 0, balEnvR = 0;
    std::vector<DelayLine> hLines; std::vector<int> hLen; float hDamp[8] {}, hv[8] {}, hGain[8] {}; std::vector<APLine> hDiff, hSide; double hLfo = 0;
    std::vector<DelayLine> sLines; std::vector<int> sLen; std::vector<float> sAP; float sLP[2] {}, sHP[2] {}, sHPx[2] {}; double sChirp = 0;

    std::pair<float, float> lean(float l, float r) {
        float c = 1 - std::exp(-1 / (0.25f * float(sampleRate)));
        balEnvL += (std::abs(l) - balEnvL) * c; balEnvR += (std::abs(r) - balEnvR) * c;
        float sum = balEnvL + balEnvR, bal = sum > 1e-6f ? (balEnvL - balEnvR) / sum : 0;
        return { 1 + 0.5f * bal, 1 - 0.5f * bal };
    }
    void plate(int frames, const float* inL, const float* inR, float* oL, float* oR, float size, float damp, bool frozen, float mix, float width, float dry) {
        float decay = frozen ? 1 : 0.25f + size * 0.72f, dampC = frozen ? 1 : 1 - damp * 0.85f, inGain = frozen ? 0.0f : 1.0f, bw = 0.9995f;
        double excursion = 8 * pScale, lfoInc = 2 * kPi / sampleRate;
        float wet = mix * 0.9f;
        auto& t = pTaps;
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            pBW += ((l + r) * 0.5f * inGain - pBW) * bw;
            float x = pBW;
            x = pIn[0].process(x, 0.75f); x = pIn[1].process(x, 0.75f); x = pIn[2].process(x, 0.625f); x = pIn[3].process(x, 0.625f);
            float side = (l - r) * 0.5f * inGain;
            side = pSide[0].process(side, 0.7f); side = pSide[1].process(side, 0.6f);
            float xL = x + side, xR = x - side;
            pLfo += lfoInc; if (pLfo > 2 * kPi) pLfo -= 2 * kPi;
            double m1 = excursion * (1 + std::sin(pLfo)) * 0.5, m2 = excursion * (1 + std::cos(pLfo)) * 0.5;
            float a = pApMod1.process(xL + pFeedR, -0.7f, m1);
            pD[0].write(a);
            pDampL += (pD[0].read(pLen[0] - 1) - pDampL) * dampC;
            float c = pAp5.process(pDampL * decay, 0.5f);
            pD[1].write(c);
            pFeedL = pD[1].read(pLen[1] - 1) * decay;
            float b = pApMod2.process(xR + pFeedL, -0.7f, m2);
            pD[2].write(b);
            pDampR += (pD[2].read(pLen[2] - 1) - pDampR) * dampC;
            float e = pAp6.process(pDampR * decay, 0.5f);
            pD[3].write(e);
            pFeedR = pD[3].read(pLen[3] - 1) * decay;
            float yl = pD[2].read(t[0]) + pD[2].read(t[1]) - pAp6.tap(t[2]) + pD[3].read(t[3]) - pD[0].read(t[4]) - pAp5.tap(t[5]) - pD[1].read(t[6]);
            float yr = pD[0].read(t[7]) + pD[0].read(t[8]) - pAp5.tap(t[9]) + pD[1].read(t[10]) - pD[2].read(t[11]) - pAp6.tap(t[12]) - pD[3].read(t[13]);
            auto [gl, gr] = lean(l, r);
            float sl = yl * 0.6f * gl, sr = yr * 0.6f * gr, w1 = width / 2 + 0.5f, w2 = (1 - width) / 2;
            oL[i] = (sl * w1 + sr * w2) * wet + l * dry; oR[i] = (sr * w1 + sl * w2) * wet + r * dry;
        }
        if (!std::isfinite(pFeedL) || !std::isfinite(pFeedR)) { pFeedL = pFeedR = pDampL = pDampR = 0; }
    }
    void spring(int frames, const float* inL, const float* inR, float* oL, float* oR, float size, float damp, bool frozen, float mix, float width, float dry) {
        const int n = springStages;
        float g = frozen ? 0.999f : 0.5f + size * 0.42f;
        float lpc = 1 - std::exp(-2 * juce::MathConstants<float>::pi * (6500 - 4800 * damp) / float(sampleRate));
        float hpc = std::exp(-2 * juce::MathConstants<float>::pi * 120 / float(sampleRate)), a = 0.62f, inGain = frozen ? 0.0f : 1.0f;
        float wet = mix * 2.6f, w1 = width / 2 + 0.5f, w2 = (1 - width) / 2;
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            sChirp += 0.6 / sampleRate; if (sChirp > 1) sChirp -= 1;
            double wob = 2.0 * std::sin(2 * kPi * sChirp);
            float outs[2] {};
            for (int sp = 0; sp < 2; ++sp) {
                float x = (sp == 0 ? l * 0.75f + r * 0.25f : r * 0.75f + l * 0.25f) * inGain;
                float hp = hpc * (sHP[sp] + x - sHPx[sp]); sHP[sp] = hp; sHPx[sp] = x;
                float v = sLines[size_t(sp)].read(double(sLen[size_t(sp)] - 1) + (sp == 0 ? wob : -wob));
                float u = hp * 0.6f + v * g, ak = sp == 0 ? a : a - 0.08f;
                int b = sp * n * 2;
                for (int k = 0; k < n; ++k) {
                    float x1 = sAP[size_t(b + 2 * k)], y1 = sAP[size_t(b + 2 * k + 1)];
                    float y = ak * u + x1 - ak * y1;
                    sAP[size_t(b + 2 * k)] = u; sAP[size_t(b + 2 * k + 1)] = y; u = y;
                }
                sLP[sp] += (u - sLP[sp]) * lpc; sLines[size_t(sp)].write(sLP[sp]); outs[sp] = sLP[sp];
            }
            oL[i] = (outs[0] * w1 + outs[1] * w2) * wet + l * dry; oR[i] = (outs[1] * w1 + outs[0] * w2) * wet + r * dry;
        }
        if (!std::isfinite(sLP[0]) || !std::isfinite(sLP[1])) { sLP[0] = sLP[1] = 0; std::fill(sAP.begin(), sAP.end(), 0.0f); }
    }
    void hall(int frames, const float* inL, const float* inR, float* oL, float* oR, float size, float damp, bool frozen, float mix, float width, float dry) {
        double rt60 = 0.6 * std::pow(20.0, double(size)), modDepth = 0.0015 * sampleRate, lfoInc = 2 * kPi * 0.37 / sampleRate;
        float dampC = frozen ? 1 : 1 - damp * 0.8f, inGain = frozen ? 0 : 0.35f, wet = mix * 0.8f, norm = 1 / std::sqrt(8.0f);
        for (int k = 0; k < 8; ++k) hGain[k] = frozen ? 1 : float(std::pow(10.0, -3 * double(hLen[size_t(k)]) / (rt60 * sampleRate)));
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            float x = (l + r) * 0.5f * inGain;
            x = hDiff[0].process(x, 0.6f); x = hDiff[1].process(x, 0.6f); x = hDiff[2].process(x, 0.5f);
            float side = (l - r) * 0.5f * inGain;
            side = hSide[0].process(side, 0.6f); side = hSide[1].process(side, 0.55f);
            float xL = x + side, xR = x - side;
            hLfo += lfoInc; if (hLfo > 2 * kPi) hLfo -= 2 * kPi;
            for (int k = 0; k < 8; ++k) {
                double mod = (k == 1 || k == 6) ? modDepth * (1 + std::sin(hLfo + k)) : 0;
                float y = hLines[size_t(k)].read(double(hLen[size_t(k)] - 1) + mod);
                hDamp[k] += (y - hDamp[k]) * dampC;
                hv[k] = hDamp[k];
            }
            float outL = hv[0] - hv[2] + hv[4] - hv[6], outR = hv[1] - hv[3] + hv[5] - hv[7];
            for (int hh = 1; hh < 8; hh *= 2)
                for (int j = 0; j < 8; j += hh * 2)
                    for (int k = j; k < j + hh; ++k) { float a = hv[k], b = hv[k + hh]; hv[k] = a + b; hv[k + hh] = a - b; }
            for (int k = 0; k < 8; ++k) {
                float sign = (k & 1) == 0 ? 1.0f : -1.0f;
                hLines[size_t(k)].write(hv[k] * norm * hGain[k] + ((k & 1) == 0 ? xL : xR) * sign);
            }
            auto [gl, gr] = lean(l, r);
            float sl = outL * 1.85f * gl, sr = outR * 1.85f * gr, w1 = width / 2 + 0.5f, w2 = (1 - width) / 2;
            oL[i] = (sl * w1 + sr * w2) * wet + l * dry; oR[i] = (sr * w1 + sl * w2) * wet + r * dry;
        }
        for (float& v : hDamp) if (!std::isfinite(v)) v = 0;
    }
};

Factory factoryFX(const std::string& k) {
    if (k == "filter") return make<FilterNode>();
    if (k == "delay") return make<DelayNode>();
    if (k == "drive") return make<DriveNode>();
    if (k == "reverb") return make<ReverbNode>();
    return nullptr;
}

} // namespace pn
