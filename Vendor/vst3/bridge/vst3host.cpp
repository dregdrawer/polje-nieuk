// A small VST3 host (see include/pn_vst3.h). Only Steinberg's interface headers (MIT) are used; the host side
// (streams, messages, parameter queues, event lists, the frame for the editor) is written here.
#define INIT_CLASS_IID
#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstattributes.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "include/pn_vst3.h"

#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <map>
#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

bool same(const TUID a, const FUID& b) { return FUnknownPrivate::iidEqual(a, b.toTUID()); }

#define PN_REFCOUNT                                                                    \
    std::atomic<int32> refs { 1 };                                                     \
    uint32 PLUGIN_API addRef() override { return ++refs; }                             \
    uint32 PLUGIN_API release() override { int32 r = --refs; if (r == 0) delete this; return r; }

#define PN_NOREFCOUNT                                                                  \
    uint32 PLUGIN_API addRef() override { return 1; }                                  \
    uint32 PLUGIN_API release() override { return 1; }

std::string utf8(const TChar* s) {
    std::string out;
    for (int i = 0; i < 128 && s[i]; ++i) {
        uint32_t c = (uint16_t)s[i];
        if (c < 0x80) out += (char)c;
        else if (c < 0x800) { out += (char)(0xC0 | (c >> 6)); out += (char)(0x80 | (c & 0x3F)); }
        else { out += (char)(0xE0 | (c >> 12)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
    }
    return out;
}

// ---- memory stream ---------------------------------------------------------------------------------
struct MemStream : IBStream, ISizeableStream {
    std::vector<uint8_t> data;
    int64 pos = 0;
    PN_REFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IBStream::iid) || same(iid, FUnknown::iid)) { addRef(); *obj = static_cast<IBStream*>(this); return kResultOk; }
        if (same(iid, ISizeableStream::iid)) { addRef(); *obj = static_cast<ISizeableStream*>(this); return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    tresult PLUGIN_API read(void* buffer, int32 n, int32* got) override {
        int64 left = (int64)data.size() - pos;
        int32 k = (int32)std::max<int64>(0, std::min<int64>(n, left));
        if (k > 0) memcpy(buffer, data.data() + pos, (size_t)k);
        pos += k;
        if (got) *got = k;
        return kResultOk;
    }
    tresult PLUGIN_API write(void* buffer, int32 n, int32* put) override {
        if (n < 0) return kInvalidArgument;
        if (pos + n > (int64)data.size()) data.resize((size_t)(pos + n));
        if (n > 0) memcpy(data.data() + pos, buffer, (size_t)n);
        pos += n;
        if (put) *put = n;
        return kResultOk;
    }
    tresult PLUGIN_API seek(int64 p, int32 mode, int64* result) override {
        int64 np = mode == kIBSeekSet ? p : mode == kIBSeekCur ? pos + p : (int64)data.size() + p;
        if (np < 0) return kInvalidArgument;
        pos = np;
        if (result) *result = pos;
        return kResultOk;
    }
    tresult PLUGIN_API tell(int64* p) override { if (p) *p = pos; return kResultOk; }
    tresult PLUGIN_API getStreamSize(int64& size) override { size = (int64)data.size(); return kResultOk; }
    tresult PLUGIN_API setStreamSize(int64 size) override { data.resize((size_t)std::max<int64>(size, 0)); return kResultOk; }
};

// ---- messages between the processor and its editor ----------------------------------------------------
struct AttributeList : IAttributeList {
    struct Value { int kind = 0; int64 i = 0; double f = 0; std::u16string s; std::vector<uint8_t> b; };
    std::map<std::string, Value> values;
    PN_REFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IAttributeList::iid) || same(iid, FUnknown::iid)) { addRef(); *obj = this; return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    tresult PLUGIN_API setInt(AttrID id, int64 v) override { auto& x = values[id]; x.kind = 1; x.i = v; return kResultOk; }
    tresult PLUGIN_API getInt(AttrID id, int64& v) override {
        auto it = values.find(id); if (it == values.end() || it->second.kind != 1) return kResultFalse; v = it->second.i; return kResultOk;
    }
    tresult PLUGIN_API setFloat(AttrID id, double v) override { auto& x = values[id]; x.kind = 2; x.f = v; return kResultOk; }
    tresult PLUGIN_API getFloat(AttrID id, double& v) override {
        auto it = values.find(id); if (it == values.end() || it->second.kind != 2) return kResultFalse; v = it->second.f; return kResultOk;
    }
    tresult PLUGIN_API setString(AttrID id, const TChar* s) override {
        auto& x = values[id]; x.kind = 3; x.s.clear();
        for (int i = 0; s && s[i]; ++i) x.s += (char16_t)s[i];
        return kResultOk;
    }
    tresult PLUGIN_API getString(AttrID id, TChar* s, uint32 sizeBytes) override {
        auto it = values.find(id); if (it == values.end() || it->second.kind != 3) return kResultFalse;
        uint32 n = sizeBytes / sizeof(TChar); if (n == 0) return kResultFalse;
        uint32 k = std::min<uint32>((uint32)it->second.s.size(), n - 1);
        for (uint32 i = 0; i < k; ++i) s[i] = (TChar)it->second.s[i];
        s[k] = 0;
        return kResultOk;
    }
    tresult PLUGIN_API setBinary(AttrID id, const void* d, uint32 size) override {
        auto& x = values[id]; x.kind = 4; x.b.assign((const uint8_t*)d, (const uint8_t*)d + size); return kResultOk;
    }
    tresult PLUGIN_API getBinary(AttrID id, const void*& d, uint32& size) override {
        auto it = values.find(id); if (it == values.end() || it->second.kind != 4) return kResultFalse;
        d = it->second.b.data(); size = (uint32)it->second.b.size(); return kResultOk;
    }
};

struct Message : IMessage {
    std::string mid;
    AttributeList* attrs = new AttributeList();
    ~Message() { attrs->release(); }
    PN_REFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IMessage::iid) || same(iid, FUnknown::iid)) { addRef(); *obj = this; return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    FIDString PLUGIN_API getMessageID() override { return mid.c_str(); }
    void PLUGIN_API setMessageID(FIDString id) override { mid = id ? id : ""; }
    IAttributeList* PLUGIN_API getAttributes() override { return attrs; }
};

struct HostApp : IHostApplication {
    PN_NOREFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IHostApplication::iid) || same(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    tresult PLUGIN_API getName(String128 name) override {
        const char* n = "polje nieuk";
        int i = 0; for (; n[i] && i < 127; ++i) name[i] = (TChar)n[i];
        name[i] = 0; return kResultOk;
    }
    tresult PLUGIN_API createInstance(TUID cid, TUID iid, void** obj) override {
        if (same(cid, IMessage::iid) && same(iid, IMessage::iid)) { *obj = static_cast<IMessage*>(new Message()); return kResultOk; }
        if (same(cid, IAttributeList::iid) && same(iid, IAttributeList::iid)) { *obj = static_cast<IAttributeList*>(new AttributeList()); return kResultOk; }
        *obj = nullptr; return kResultFalse;
    }
};
HostApp hostApp;

// ---- what the processor gets each block ------------------------------------------------------------------
struct ValueQueue : IParamValueQueue {
    ParamID id = 0; int32 count = 0;
    int32 offs[16]; ParamValue vals[16];
    PN_NOREFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IParamValueQueue::iid) || same(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return count; }
    tresult PLUGIN_API getPoint(int32 i, int32& o, ParamValue& v) override {
        if (i < 0 || i >= count) return kResultFalse; o = offs[i]; v = vals[i]; return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 o, ParamValue v, int32& index) override {
        // keep it simple: one value per block (the newest)
        if (count > 0 && offs[count - 1] >= o) { vals[count - 1] = v; index = count - 1; return kResultOk; }
        if (count >= 16) { vals[15] = v; index = 15; return kResultOk; }
        offs[count] = o; vals[count] = v; index = count++; return kResultOk;
    }
};

struct ParamChanges : IParameterChanges {
    static constexpr int kMax = 128;
    ValueQueue q[kMax]; int32 n = 0;
    PN_NOREFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IParameterChanges::iid) || same(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    int32 PLUGIN_API getParameterCount() override { return n; }
    IParamValueQueue* PLUGIN_API getParameterData(int32 i) override { return i >= 0 && i < n ? &q[i] : nullptr; }
    IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id, int32& index) override {
        for (int32 i = 0; i < n; ++i) if (q[i].id == id) { index = i; return &q[i]; }
        if (n >= kMax) return nullptr;
        q[n].id = id; q[n].count = 0; index = n; return &q[n++];
    }
    void set(ParamID id, double v) { int32 k; if (auto* qq = addParameterData(id, k)) qq->addPoint(0, v, k); }
};

struct EventList : IEventList {
    static constexpr int kMax = 256;
    Event ev[kMax]; int32 n = 0;
    PN_NOREFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IEventList::iid) || same(iid, FUnknown::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    int32 PLUGIN_API getEventCount() override { return n; }
    tresult PLUGIN_API getEvent(int32 i, Event& e) override { if (i < 0 || i >= n) return kResultFalse; e = ev[i]; return kResultOk; }
    tresult PLUGIN_API addEvent(Event& e) override { if (n >= kMax) return kResultFalse; ev[n++] = e; return kResultOk; }
};

/// One writer thread, one reader thread.
struct Ring {
    struct E { ParamID id; double v; };
    static constexpr uint32_t N = 1024;
    E e[N];
    std::atomic<uint32_t> head { 0 }, tail { 0 };
    bool push(ParamID id, double v) {
        uint32_t h = head.load(std::memory_order_relaxed), t = tail.load(std::memory_order_acquire);
        if (h - t >= N) return false;
        e[h % N] = { id, v };
        head.store(h + 1, std::memory_order_release);
        return true;
    }
    bool pop(E& out) {
        uint32_t t = tail.load(std::memory_order_relaxed), h = head.load(std::memory_order_acquire);
        if (t == h) return false;
        out = e[t % N];
        tail.store(t + 1, std::memory_order_release);
        return true;
    }
};

struct Module { CFBundleRef bundle = nullptr; IPluginFactory* factory = nullptr; };
std::map<std::string, Module> modules;     // bundles stay loaded once opened

Module* openModule(const std::string& path, std::string& err) {
    auto it = modules.find(path);
    if (it != modules.end()) return &it->second;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8*)path.c_str(), (CFIndex)path.size(), true);
    if (!url) { err = "bad path"; return nullptr; }
    CFBundleRef b = CFBundleCreate(nullptr, url);
    CFRelease(url);
    if (!b) { err = "not a bundle"; return nullptr; }
    if (!CFBundleLoadExecutable(b)) { CFRelease(b); err = "couldn't load the plugin's code (wrong architecture?)"; return nullptr; }
    typedef bool (*Entry)(CFBundleRef);
    auto entry = (Entry)CFBundleGetFunctionPointerForName(b, CFSTR("bundleEntry"));
    if (!entry) entry = (Entry)CFBundleGetFunctionPointerForName(b, CFSTR("BundleEntry"));
    if (entry && !entry(b)) { err = "the plugin refused to start"; return nullptr; }
    typedef IPluginFactory* (*GetFactory)();
    auto gf = (GetFactory)CFBundleGetFunctionPointerForName(b, CFSTR("GetPluginFactory"));
    IPluginFactory* f = gf ? gf() : nullptr;
    if (!f) { err = "no plugin factory"; return nullptr; }
    Module m; m.bundle = b; m.factory = f;
    return &(modules[path] = m);
}

} // namespace

// ---- the plugin ---------------------------------------------------------------------------------------------
struct PNVst3 : IComponentHandler, IPlugFrame {
    IComponent* component = nullptr;
    IAudioProcessor* processor = nullptr;
    IEditController* controller = nullptr;
    bool separate = false;
    IConnectionPoint *compCP = nullptr, *ctrlCP = nullptr;
    IPlugView* view = nullptr;
    void (*resized)(void*, int, int) = nullptr; void* resizedCtx = nullptr;

    std::string name, vendor;
    bool instrument = false;
    int maxBlock = 64;
    double sampleRate = 48000;
    std::vector<ParamID> paramIds;
    std::vector<std::string> paramNames;

    // busses: every channel of every bus gets a buffer; the main bus carries ours
    std::vector<AudioBusBuffers> inBus, outBus;
    std::vector<std::vector<float*>> inPtr, outPtr;
    std::vector<std::vector<float>> scratch;
    int inChannels = 0, outChannels = 0;     // main busses
    std::vector<float> silence;

    ParamChanges inChanges, outChanges;
    EventList events;
    Ring toAudio, toEditor;
    ProcessContext pc {};

    PN_NOREFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (same(iid, IComponentHandler::iid) || same(iid, FUnknown::iid)) { *obj = static_cast<IComponentHandler*>(this); return kResultOk; }
        if (same(iid, IPlugFrame::iid)) { *obj = static_cast<IPlugFrame*>(this); return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    // the editor moved a control: send it to the processor
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue v) override { toAudio.push(id, v); return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }
    tresult PLUGIN_API resizeView(IPlugView* v, ViewRect* r) override {
        if (!v || !r) return kInvalidArgument;
        if (resized) resized(resizedCtx, r->getWidth(), r->getHeight());
        v->onSize(r);
        return kResultTrue;
    }

    float* buffer() { scratch.emplace_back((size_t)maxBlock, 0.f); return scratch.back().data(); }

    void setupBusses() {
        int nIn = component->getBusCount(kAudio, kInput), nOut = component->getBusCount(kAudio, kOutput);
        std::vector<SpeakerArrangement> ins(nIn), outs(nOut);
        for (int i = 0; i < nIn; ++i) { processor->getBusArrangement(kInput, i, ins[i]); }
        for (int i = 0; i < nOut; ++i) { processor->getBusArrangement(kOutput, i, outs[i]); }
        if (nIn > 0) ins[0] = SpeakerArr::kStereo;
        if (nOut > 0) outs[0] = SpeakerArr::kStereo;
        if (processor->setBusArrangements(ins.data(), nIn, outs.data(), nOut) != kResultTrue) {
            for (int i = 0; i < nIn; ++i) processor->getBusArrangement(kInput, i, ins[i]);
            for (int i = 0; i < nOut; ++i) processor->getBusArrangement(kOutput, i, outs[i]);
        }
        for (int i = 0; i < nIn; ++i) component->activateBus(kAudio, kInput, i, i == 0);
        for (int i = 0; i < nOut; ++i) component->activateBus(kAudio, kOutput, i, i == 0);
        int nEv = component->getBusCount(kEvent, kInput);
        for (int i = 0; i < nEv; ++i) component->activateBus(kEvent, kInput, i, i == 0);

        scratch.reserve(256);
        inBus.resize(nIn); inPtr.resize(nIn);
        for (int i = 0; i < nIn; ++i) {
            int ch = SpeakerArr::getChannelCount(ins[i]);
            if (i == 0) inChannels = ch;
            for (int c = 0; c < ch; ++c) inPtr[i].push_back(buffer());
            inBus[i].numChannels = ch; inBus[i].silenceFlags = 0;
            inBus[i].channelBuffers32 = inPtr[i].empty() ? nullptr : inPtr[i].data();
        }
        outBus.resize(nOut); outPtr.resize(nOut);
        for (int i = 0; i < nOut; ++i) {
            int ch = SpeakerArr::getChannelCount(outs[i]);
            if (i == 0) outChannels = ch;
            for (int c = 0; c < ch; ++c) outPtr[i].push_back(buffer());
            outBus[i].numChannels = ch; outBus[i].silenceFlags = 0;
            outBus[i].channelBuffers32 = outPtr[i].empty() ? nullptr : outPtr[i].data();
        }
        instrument = instrument || (nIn == 0 && nEv > 0);
    }

    void readParams() {
        paramIds.clear(); paramNames.clear();
        if (!controller) return;
        int32 n = controller->getParameterCount();
        for (int32 i = 0; i < n; ++i) {
            ParameterInfo info {};
            if (controller->getParameterInfo(i, info) != kResultOk) continue;
            if (!(info.flags & ParameterInfo::kCanAutomate) || (info.flags & ParameterInfo::kIsReadOnly)) continue;
            paramIds.push_back(info.id);
            paramNames.push_back(utf8(info.title));
        }
    }

    void syncControllerFromComponent() {
        if (!controller || !separate) return;
        MemStream* s = new MemStream();
        if (component->getState(s) == kResultOk) { s->pos = 0; controller->setComponentState(s); }
        s->release();
    }

    ~PNVst3() {
        if (view) { view->removed(); view->release(); view = nullptr; }
        if (processor) processor->setProcessing(false);
        if (component) component->setActive(false);
        if (compCP && ctrlCP) { compCP->disconnect(ctrlCP); ctrlCP->disconnect(compCP); }
        if (compCP) compCP->release();
        if (ctrlCP) ctrlCP->release();
        if (controller) {
            controller->setComponentHandler(nullptr);
            if (separate) controller->terminate();
            controller->release();
        }
        if (processor) processor->release();
        if (component) { component->terminate(); component->release(); }
    }
};

extern "C" {

PNVst3* pnvst3_load(const char* bundlePath, double sampleRate, int maxBlock, char* err, int errCap) {
    auto fail = [&](const std::string& why) -> PNVst3* {
        if (err && errCap > 0) { strncpy(err, why.c_str(), (size_t)errCap - 1); err[errCap - 1] = 0; }
        return nullptr;
    };
    std::string e;
    Module* m = openModule(bundlePath, e);
    if (!m) return fail(e);
    IPluginFactory* f = m->factory;
    PFactoryInfo fi {}; f->getFactoryInfo(&fi);
    IPluginFactory2* f2 = nullptr; f->queryInterface(IPluginFactory2::iid, (void**)&f2);

    int32 n = f->countClasses();
    int found = -1; PClassInfo ci {};
    for (int32 i = 0; i < n; ++i) {
        PClassInfo c {};
        if (f->getClassInfo(i, &c) == kResultOk && strcmp(c.category, kVstAudioEffectClass) == 0) { found = i; ci = c; break; }
    }
    if (found < 0) { if (f2) f2->release(); return fail("no audio plugin in this bundle"); }

    PNVst3* p = new PNVst3();
    p->maxBlock = std::max(maxBlock, 16);
    p->sampleRate = sampleRate;
    p->name = ci.name;
    p->vendor = fi.vendor;
    if (f2) {
        PClassInfo2 c2 {};
        if (f2->getClassInfo2(found, &c2) == kResultOk) {
            if (strstr(c2.subCategories, "Instrument")) p->instrument = true;
            if (c2.vendor[0]) p->vendor = c2.vendor;
        }
        f2->release();
    }
    p->silence.assign((size_t)p->maxBlock, 0.f);

    if (f->createInstance(ci.cid, IComponent::iid, (void**)&p->component) != kResultOk || !p->component) { delete p; return fail("couldn't create the plugin"); }
    if (p->component->initialize(&hostApp) != kResultOk) { p->component->release(); p->component = nullptr; delete p; return fail("the plugin didn't initialise"); }
    if (p->component->queryInterface(IAudioProcessor::iid, (void**)&p->processor) != kResultOk || !p->processor) { delete p; return fail("not an audio processor"); }
    if (p->component->queryInterface(IEditController::iid, (void**)&p->controller) != kResultOk || !p->controller) {
        p->controller = nullptr;
        TUID ccid;
        if (p->component->getControllerClassId(ccid) == kResultOk &&
            f->createInstance(ccid, IEditController::iid, (void**)&p->controller) == kResultOk && p->controller) {
            if (p->controller->initialize(&hostApp) != kResultOk) { p->controller->release(); p->controller = nullptr; }
            else p->separate = true;
        }
    }
    if (p->controller) {
        p->controller->setComponentHandler(p);
        if (p->separate) {
            p->component->queryInterface(IConnectionPoint::iid, (void**)&p->compCP);
            p->controller->queryInterface(IConnectionPoint::iid, (void**)&p->ctrlCP);
            if (p->compCP && p->ctrlCP) { p->compCP->connect(p->ctrlCP); p->ctrlCP->connect(p->compCP); }
        }
        p->syncControllerFromComponent();
    }
    p->setupBusses();
    ProcessSetup setup { kRealtime, kSample32, p->maxBlock, sampleRate };
    if (p->processor->setupProcessing(setup) != kResultOk) { delete p; return fail("the plugin can't run at this sample rate"); }
    p->component->setActive(true);
    p->processor->setProcessing(true);
    p->readParams();
    return p;
}

void pnvst3_free(PNVst3* p) { delete p; }
int pnvst3_is_instrument(PNVst3* p) { return p->instrument ? 1 : 0; }
const char* pnvst3_name(PNVst3* p) { return p->name.c_str(); }
const char* pnvst3_vendor(PNVst3* p) { return p->vendor.c_str(); }
int pnvst3_param_count(PNVst3* p) { return (int)p->paramIds.size(); }
void pnvst3_param_name(PNVst3* p, int i, char* out, int cap) {
    if (cap <= 0) return;
    std::string s = i >= 0 && i < (int)p->paramNames.size() ? p->paramNames[(size_t)i] : "";
    strncpy(out, s.c_str(), (size_t)cap - 1); out[cap - 1] = 0;
}
double pnvst3_param_value(PNVst3* p, int i) {
    if (!p->controller || i < 0 || i >= (int)p->paramIds.size()) return 0;
    return p->controller->getParamNormalized(p->paramIds[(size_t)i]);
}

void pnvst3_note(PNVst3* p, int on, int pitch, float velocity, int offset) {
    Event e {};
    e.busIndex = 0; e.sampleOffset = offset; e.flags = Event::kIsLive;
    if (on) {
        e.type = Event::kNoteOnEvent;
        e.noteOn.channel = 0; e.noteOn.pitch = (int16)pitch; e.noteOn.tuning = 0;
        e.noteOn.velocity = velocity; e.noteOn.length = 0; e.noteOn.noteId = -1;
    } else {
        e.type = Event::kNoteOffEvent;
        e.noteOff.channel = 0; e.noteOff.pitch = (int16)pitch; e.noteOff.velocity = velocity;
        e.noteOff.noteId = -1; e.noteOff.tuning = 0;
    }
    p->events.addEvent(e);
}

void pnvst3_param(PNVst3* p, int i, double v) {
    if (i < 0 || i >= (int)p->paramIds.size()) return;
    ParamID id = p->paramIds[(size_t)i];
    p->inChanges.set(id, v);
    p->toEditor.push(id, v);
}

void pnvst3_process(PNVst3* p, const float* inL, const float* inR, float* outL, float* outR, int frames, const PNVst3Time* t) {
    frames = std::min(frames, p->maxBlock);
    Ring::E ch;
    while (p->toAudio.pop(ch)) p->inChanges.set(ch.id, ch.v);
    // main input: our stereo pair; every other bus: silence
    for (size_t b = 0; b < p->inPtr.size(); ++b)
        for (size_t c = 0; c < p->inPtr[b].size(); ++c) {
            const float* src = b == 0 ? (c == 0 ? inL : c == 1 ? inR : nullptr) : nullptr;
            if (b == 0 && c == 0 && !src) src = inR;
            if (src) memcpy(p->inPtr[b][c], src, sizeof(float) * (size_t)frames);
            else memset(p->inPtr[b][c], 0, sizeof(float) * (size_t)frames);
        }
    if (p->inPtr.size() > 0 && p->inPtr[0].size() == 1 && inL && inR)        // mono bus: both sides
        for (int i = 0; i < frames; ++i) p->inPtr[0][0][i] = 0.5f * (inL[i] + inR[i]);

    ProcessContext& pc = p->pc;
    pc.state = ProcessContext::kTempoValid | ProcessContext::kProjectTimeMusicValid | ProcessContext::kBarPositionValid |
               ProcessContext::kTimeSigValid | (t && t->playing ? ProcessContext::kPlaying : 0);
    pc.sampleRate = p->sampleRate;
    pc.tempo = t ? t->tempo : 120;
    pc.projectTimeMusic = t ? t->beat : 0;
    pc.barPositionMusic = t ? (double)((long long)(t->beat / 4) * 4) : 0;
    pc.projectTimeSamples = t ? t->samplePos : 0;
    pc.continousTimeSamples = pc.projectTimeSamples;
    pc.timeSigNumerator = 4; pc.timeSigDenominator = 4;

    p->outChanges.n = 0;
    ProcessData d;
    d.processMode = kRealtime;
    d.symbolicSampleSize = kSample32;
    d.numSamples = frames;
    d.numInputs = (int32)p->inBus.size();
    d.numOutputs = (int32)p->outBus.size();
    d.inputs = p->inBus.empty() ? nullptr : p->inBus.data();
    d.outputs = p->outBus.empty() ? nullptr : p->outBus.data();
    d.inputParameterChanges = &p->inChanges;
    d.outputParameterChanges = &p->outChanges;
    d.inputEvents = &p->events;
    d.outputEvents = nullptr;
    d.processContext = &pc;
    for (auto& b : p->outBus) b.silenceFlags = 0;
    p->processor->process(d);
    p->inChanges.n = 0;
    p->events.n = 0;
    // meters / values the processor reports go to the editor
    for (int32 i = 0; i < p->outChanges.n; ++i) {
        auto& q = p->outChanges.q[i];
        if (q.count > 0) p->toEditor.push(q.id, q.vals[q.count - 1]);
    }

    if (p->outPtr.empty() || p->outPtr[0].empty()) {
        memset(outL, 0, sizeof(float) * (size_t)frames); memset(outR, 0, sizeof(float) * (size_t)frames); return;
    }
    memcpy(outL, p->outPtr[0][0], sizeof(float) * (size_t)frames);
    memcpy(outR, p->outPtr[0].size() > 1 ? p->outPtr[0][1] : p->outPtr[0][0], sizeof(float) * (size_t)frames);
}

void pnvst3_idle(PNVst3* p) {
    Ring::E ch;
    while (p->toEditor.pop(ch)) if (p->controller) p->controller->setParamNormalized(ch.id, ch.v);
}

int pnvst3_get_state(PNVst3* p, unsigned char** data, int* length) {
    MemStream* c = new MemStream(); MemStream* k = new MemStream();
    p->component->getState(c);
    if (p->controller && p->separate) p->controller->getState(k);
    uint32_t cl = (uint32_t)c->data.size(), kl = (uint32_t)k->data.size();
    size_t total = 4 + 4 + cl + 4 + kl;
    unsigned char* out = (unsigned char*)malloc(total);
    memcpy(out, "PNV3", 4);
    memcpy(out + 4, &cl, 4); if (cl) memcpy(out + 8, c->data.data(), cl);
    memcpy(out + 8 + cl, &kl, 4); if (kl) memcpy(out + 12 + cl, k->data.data(), kl);
    c->release(); k->release();
    *data = out; *length = (int)total;
    return 1;
}

int pnvst3_set_state(PNVst3* p, const unsigned char* data, int length) {
    if (length < 12 || memcmp(data, "PNV3", 4) != 0) return 0;
    uint32_t cl, kl;
    memcpy(&cl, data + 4, 4);
    if ((size_t)length < 12 + (size_t)cl) return 0;
    memcpy(&kl, data + 8 + cl, 4);
    if ((size_t)length < 12 + (size_t)cl + kl) return 0;
    MemStream* c = new MemStream(); c->data.assign(data + 8, data + 8 + cl);
    p->component->setState(c);
    if (p->controller) {
        c->pos = 0; p->controller->setComponentState(c);
        if (p->separate && kl) { MemStream* k = new MemStream(); k->data.assign(data + 12 + cl, data + 12 + cl + kl); p->controller->setState(k); k->release(); }
    }
    c->release();
    return 1;
}

int pnvst3_has_editor(PNVst3* p) { return p->controller ? 1 : 0; }

int pnvst3_open_editor(PNVst3* p, void* parent, int* w, int* h, void (*resized)(void*, int, int), void* ctx) {
    if (!p->controller) return 0;
    if (p->view) { p->view->removed(); p->view->release(); p->view = nullptr; }
    IPlugView* v = p->controller->createView(ViewType::kEditor);
    if (!v) return 0;
    if (v->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) { v->release(); return 0; }
    p->resized = resized; p->resizedCtx = ctx;
    v->setFrame(p);
    ViewRect r {};
    v->getSize(&r);
    if (w) *w = r.getWidth();
    if (h) *h = r.getHeight();
    if (v->attached(parent, kPlatformTypeNSView) != kResultOk) { v->setFrame(nullptr); v->release(); return 0; }
    p->view = v;
    return 1;
}

void pnvst3_close_editor(PNVst3* p) {
    if (!p->view) return;
    p->view->removed();
    p->view->setFrame(nullptr);
    p->view->release();
    p->view = nullptr;
    p->resized = nullptr;
}

} // extern "C"
