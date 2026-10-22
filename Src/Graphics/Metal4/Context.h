// Supermodel native Metal 4 backend. GPL-3.0-or-later.
#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace SupermodelMetal4 {
struct NativeState;

// Owned and used by the render thread. No OpenGL context or legacy Metal queue.
class Context final {
public:
    Context();
    ~Context();
    Context(const Context&) = delete;
    Context& operator=(const Context&) = delete;

    // metalLayer is a CAMetalLayer owned by the window integration.
    bool Initialize(void* metalLayer, const char* libraryPath);
    bool Resize(uint32_t width, uint32_t height, bool vsync);
    void SetPresentationInterval(double seconds);
    bool BeginFrame();
    bool SubmitFrame();
    // Submit and wait for visibility/readback, then continue the same frame.
    bool Flush();
    bool WaitIdle();
    void Shutdown();
    std::string Error() const;
    std::string DeviceName() const;
    bool IsFrameActive() const;
    bool ReadRGBA(std::vector<uint8_t>& pixels,uint32_t& width,uint32_t& height);

    // Available only to the native Objective-C++ implementation units.
    NativeState& Native();

private:
    std::unique_ptr<NativeState> m_native;
};
Context& GetContext();
}
