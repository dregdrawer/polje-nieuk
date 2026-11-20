#include "Window.h"

class PoljeNieukApp : public juce::JUCEApplication {
public:
    const juce::String getApplicationName() override { return "polje nieuk"; }
    const juce::String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override { return false; }

    void initialise(const juce::String&) override { window = std::make_unique<Window>(); }
    void shutdown() override { window.reset(); }
    void systemRequestedQuit() override { quit(); }

private:
    class Window : public juce::DocumentWindow {
    public:
        Window() : DocumentWindow("polje nieuk", juce::Colours::black, DocumentWindow::allButtons) {
            setUsingNativeTitleBar(true);
            setTitleBarHeight(0);      // else JUCE treats the top of our own top bar as the window's caption (drag / double-click zoom)
            setContentOwned(new pn::MainComponent(), false);   // the window sets the content's size, never the other way
            setResizable(true, true);
            centreWithSize(1280, 800);
            setResizeLimits(800, 500, 10000, 10000);
            restoreWindowStateFromString(pn::settings().getValue("window"));
            setVisible(true);
        }
        ~Window() override { pn::settings().setValue("window", getWindowStateAsString()); pn::settings().saveIfNeeded(); }
        void closeButtonPressed() override { juce::JUCEApplication::getInstance()->systemRequestedQuit(); }
    };
    std::unique_ptr<Window> window;
};

START_JUCE_APPLICATION(PoljeNieukApp)
