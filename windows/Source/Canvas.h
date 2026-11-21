// The patcher canvas (NodesHost.swift + PatchCanvasView.swift): boxes, notes, groups and cables drawn the way
// Max / Pure Data draw a patcher — plain drawing calls at the exact zoom. Each box's settled drawing is kept as
// a bitmap at the zoom it was drawn at (sub-pixel position baked in, so it sits on whole pixels and stays sharp);
// while a zoom is under way that bitmap is scaled, and once the zoom pauses the boxes are drawn sharp again a few
// per frame. Moving parts (meters, playheads, modulated rows) are drawn over it when their signature changes.
#pragma once
#include "Boxes.h"

namespace pn {

class ObjectFinder;

class Canvas : public juce::Component, private juce::Timer, public juce::FileDragAndDropTarget, public juce::DragAndDropTarget, private juce::TextEditor::Listener {
public:
    explicit Canvas(AppModel& m);
    ~Canvas() override;
    void paint(juce::Graphics&) override;
    void resized() override;
    void mouseDown(const juce::MouseEvent&) override;
    void mouseDrag(const juce::MouseEvent&) override;
    void mouseUp(const juce::MouseEvent&) override;
    void mouseMove(const juce::MouseEvent&) override;
    void mouseExit(const juce::MouseEvent&) override;
    void mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails&) override;
    void mouseMagnify(const juce::MouseEvent&, float scale) override;
    bool keyPressed(const juce::KeyPress&) override;
    bool isInterestedInFileDrag(const juce::StringArray&) override { return true; }
    void fileDragMove(const juce::StringArray&, int x, int y) override;
    void fileDragExit(const juce::StringArray&) override;
    void filesDropped(const juce::StringArray& files, int x, int y) override;
    bool isInterestedInDragSource(const SourceDetails& d) override { return d.description.isString(); }
    void itemDragMove(const SourceDetails& d) override { dropHover(d.localPosition.toFloat()); }
    void itemDragExit(const SourceDetails&) override { dropHover(std::nullopt); }
    void itemDropped(const SourceDetails& d) override { filesDropped({ d.description.toString() }, d.localPosition.x, d.localPosition.y); }
    void sync();
    void viewportChanged();
    void dragged();
    void closeFinder();
    void openFinder(Pt canvasPoint);

    struct Part { LivePart lp; int64_t last = INT64_MIN; int phase = 0; };
    struct Item {
        enum Kind { module, text, grp } kind = module;
        juce::String id;
        PatchNode node;
        const ModuleSpec* spec = nullptr;
        PatchGroup group;
        std::unique_ptr<BoxGeo> geo;
        std::unique_ptr<NativeDisplay> display;
        std::set<int> liveRows;
        std::vector<Part> parts;
        Rect rect;                    // canvas points
        bool selected = false, dropTarget = false, editing = false;
        int64_t key = 0;
        bool hasKey = false;
        // the settled drawing
        juce::Image cache;
        float cacheScale = 0, cachePx = 0;
        Pt fracPx;
        float marginPx = 0;
        bool dirty = true;
        float margin() const { return kind == module ? BoxLayout::pad : 0.0f; }
    };

private:
    enum class Region { port, button, title, grab, trigger, row, display, grip, text, group, groupName, nothing };
    struct Hit { Region region = Region::nothing; int index = -1; bool output = false; BoxGeo::Button button = BoxGeo::collapse; };
    struct Press {
        Item* item; Hit hit; Pt startScreen; PointerInfo info;
        bool dragging = false, longFired = false, autoRecWasOn = false;
        std::optional<Pt> resizeStart; std::optional<float> rowStart;
        double pressedAt = 0;
    };

    void timerCallback() override;
    void textEditorTextChanged(juce::TextEditor&) override;
    void textEditorReturnKeyPressed(juce::TextEditor&) override;
    void textEditorEscapeKeyPressed(juce::TextEditor&) override;
    void textEditorFocusLost(juce::TextEditor&) override;

    int64_t keyFor(const PatchNode& n, const std::vector<const PatchCable*>& cables, const std::vector<const PatchNode*>& related);
    void update(Item& it);
    std::vector<LivePart> partsFor(Item& it);
    void renderCache(Item& it, float s, float px);
    void drawItem(juce::Graphics& g, Item& it, float s, Pt o, float px);
    void drawParts(juce::Graphics& g, Item& it, float s, Pt o);
    Rect screenRect(const Item& it) const;
    Pt dragShift(const juce::String& id) const;
    std::vector<Item*> allItems();
    Item* itemAt(Pt screen);
    Pt local(const Item& it, Pt screen) const;
    Hit region(Item& it, Pt p);
    bool began(Pt screen, const juce::MouseEvent& e);
    void moved(Pt screen);
    void ended(Pt screen, bool cancelled = false);
    void showMenu(const std::vector<MenuItem>& items, Pt screen);
    void showBoxMenu(const juce::String& id, Pt screen);      // right-click / long-press a box's title bar
    std::optional<juce::String> hitCable(Pt screen);
    std::optional<std::pair<Pt, Pt>> cableEnds(const PatchCable& c);
    void hovered(std::optional<Pt> screen);
    bool dropHover(std::optional<Pt> screen);
    void startEditing(const juce::String& id, bool isGroup);
    void finishEditing();
    void placeEditor();
    float pixelScale() const;

    AppModel& model;
    std::map<juce::String, std::unique_ptr<Item>> items, groupItems;
    std::vector<juce::String> order;
    std::optional<Press> press;
    // background gestures
    bool panning = false, bgPressed = false;
    Pt bgStart, panStart;
    std::optional<Rect> marquee;
    std::optional<Pt> hover;
    std::vector<HelpTopic> helpShown;
    Item* dropItem = nullptr;
    // zoom settling
    float drawnScale = 0;
    double settleAt = 0;
    std::vector<Item*> queue;
    // ticking
    int frame = 0;
    double longPressAt = 0;
    std::unique_ptr<juce::TextEditor> editor;
    juce::String editingID;
    bool editingGroup = false;
    std::unique_ptr<ObjectFinder> finder;
    juce::Rectangle<int> deleteButton;
    juce::Image gridImage;
    bool bgRight = false;
    // view > Patch map: every box small, the view as a frame; click / drag it to go there
    Rect mapRect() const;
    Rect mapExtent() const;
    void mapGo(Pt p);
    bool mapDragging = false;
    std::optional<Rect> mapHeld;              // the extent, kept still while you drag on the map
    juce::Image bgImage; int bgW = 0, bgH = 0, bgVersion = -1; float bgPx = 0;   // the background picture, scaled to fill the window
    juce::Path cablePlain, cableDashed, cableSel, cableDashedStroke;
    bool cablesDirty = true; float dashedFor = 0;
    void rebuildCables();
    float gridStep = 0, gridPx = 0; int gridW = 0, gridH = 0;
    juce::Colour gridColour;
};

/// The module list that opens where you double-click (PatchCanvasView.swift ObjectFinder).
class ObjectFinder : public juce::Component, public juce::SettableTooltipClient {
public:
    ObjectFinder(AppModel& m, Pt canvasPoint);
    void paint(juce::Graphics&) override;
    void mouseMove(const juce::MouseEvent&) override;
    void mouseExit(const juce::MouseEvent&) override;
    void mouseUp(const juce::MouseEvent&) override;
    void mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails&) override;
    static constexpr int width = 584;
    int contentHeight() const { return contentH; }
    std::function<void()> onClose;
private:
    struct Entry { const ModuleSpec* spec; juce::Rectangle<float> r; };
    std::vector<Entry> entries;
    std::vector<std::pair<juce::String, juce::Rectangle<float>>> headings;
    AppModel& model;
    Pt at;
    int hoverIndex = -1, contentH = 0;
    float scroll = 0;
};

} // namespace pn
