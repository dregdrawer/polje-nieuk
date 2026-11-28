#include "Window.h"
#include "ModulesMIDI.h"

class PoljeNieukApp : public juce::JUCEApplication {
public:
    const juce::String getApplicationName() override { return "polje nieuk"; }
    const juce::String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override { return false; }

    void initialise(const juce::String&) override { window = std::make_unique<Window>(); }
    void shutdown() override { window.reset(); pn::MidiHub::shared().shutdown(); }
    void systemRequestedQuit() override { quit(); }

private:
    class Window : public juce::DocumentWindow {
    public:
        Window() : DocumentWindow("polje nieuk", juce::Colours::black, DocumentWindow::allButtons) {
            setUsingNativeTitleBar(true);
            setTitleBarHeight(0);      // else JUCE treats the top of our own top bar as the window's caption (drag / double-click zoom)
            setContentOwned(new pn::MainComponent(), false);   // the window sets the content's size, never the other way
            setResizable(true, true);
            // 1280 × 800, or smaller to fit the screen (laptops, scaled displays)
            if (auto* d = juce::Desktop::getInstance().getDisplays().getPrimaryDisplay()) {
                auto area = d->userArea;
                centreWithSize(std::min(1280, area.getWidth() - 40), std::min(800, area.getHeight() - 60));
            } else centreWithSize(1280, 800);
            setResizeLimits(800, 500, 10000, 10000);
            restoreWindowStateFromString(pn::settings().getValue("window"));
            // a window remembered on a screen that's gone: bring it back on screen
            if (auto* d = juce::Desktop::getInstance().getDisplays().getDisplayForRect(getScreenBounds()))
                if (!d->userArea.intersects(getScreenBounds())) centreWithSize(getWidth(), getHeight());
            setVisible(true);
        }
        ~Window() override { pn::settings().setValue("window", getWindowStateAsString()); pn::settings().saveIfNeeded(); }
        void mouseDoubleClick(const juce::MouseEvent&) override {}
        void closeButtonPressed() override { juce::JUCEApplication::getInstance()->systemRequestedQuit(); }
    };
    std::unique_ptr<Window> window;
};

START_JUCE_APPLICATION(PoljeNieukApp)
