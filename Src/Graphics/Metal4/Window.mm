// SDL owns the NSWindow; the native renderer owns its Metal view and GPU state.
#include "Window.h"
#include "Native.h"
#include <SDL.h>
#include <SDL_syswm.h>
#import <AppKit/AppKit.h>
#include <mach-o/dyld.h>
#include <filesystem>

namespace SupermodelMetal4 {
namespace { SDL_MetalView metalView=nullptr; id<NSObject> gameActivity=nil; }

bool PrepareAppRuntimeDirectory() {
    // LaunchServices may start a bundle in /. Keep all writable runtime data
    // beside the external build, exactly as the build/run entrypoint does.
    uint32_t count=0;
    _NSGetExecutablePath(nullptr,&count);
    std::vector<char> path(count);
    if (_NSGetExecutablePath(path.data(),&count)!=0) return false;
    auto executableDirectory=std::filesystem::path(path.data()).parent_path();
    auto contents=executableDirectory.parent_path();
    auto bundle=contents.parent_path();
    if (executableDirectory.filename()!="MacOS" || contents.filename()!="Contents" ||
        bundle.extension()!=".app") return true; // Preserve raw CLI behavior.
    auto runtime=bundle.parent_path()/"Runtime";
    std::error_code error;
    std::filesystem::current_path(runtime,error);
    if (error) return GetContext().Native().Fail("Cannot enter the external Supermodel runtime directory: "+error.message());
    return true;
}

bool AttachWindow(SDL_Window* window) {
    if (metalView) return GetContext().Native().Fail("A Metal 4 window is already attached");
    SDL_SysWMinfo info{};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window,&info) || info.subsystem!=SDL_SYSWM_COCOA)
        return GetContext().Native().Fail("Cannot access the Cocoa game window");
    // SDL recreates this transient window from emulator configuration. AppKit
    // cannot restore its live game state, and archiving changing FPS titles
    // synchronously in the event pump stalls the emulation deadline.
    info.info.cocoa.window.restorable=NO;
    [info.info.cocoa.window disableSnapshotRestoration];
    metalView=SDL_Metal_CreateView(window);
    if (!metalView) return GetContext().Native().Fail(std::string("SDL Metal view: ")+SDL_GetError());
    uint32_t count=0;
    _NSGetExecutablePath(nullptr,&count);
    std::vector<char> path(count);
    if (_NSGetExecutablePath(path.data(),&count)!=0) {
        DetachWindow();return GetContext().Native().Fail("Cannot locate native Metal shader library");
    }
    auto library=(std::filesystem::path(path.data()).parent_path()/"Supermodel.metallib").string();
    if (!GetContext().Initialize(SDL_Metal_GetLayer(metalView),library.c_str())) {
        SDL_Metal_DestroyView(metalView);metalView=nullptr;return false;
    }
    return true;
}

void SetGameActive(bool active) {
    if (active && !gameActivity) {
        // The frame loop runs outside AppKit's event callbacks. Express its
        // interactive animation deadlines to prevent background throttling.
        gameActivity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInteractive
            reason:@"Interactive Model 3 emulation and Metal presentation"];
    } else if (!active && gameActivity) {
        [NSProcessInfo.processInfo endActivity:gameActivity];
        gameActivity=nil;
    }
}

void DetachWindow() {
    SetGameActive(false);
    GetContext().Shutdown();
    if (metalView) {SDL_Metal_DestroyView(metalView);metalView=nullptr;}
}

void DrawableSize(SDL_Window* window,int& width,int& height) { SDL_Metal_GetDrawableSize(window,&width,&height); }

bool ResizeWindow(SDL_Window* window,bool vsync) {
    int width=0,height=0;DrawableSize(window,width,height);
    if (width<0 || height<0) return GetContext().Native().Fail("Negative SDL Metal drawable size");
    return GetContext().Resize(width,height,vsync);
}

bool SetClip(unsigned x,unsigned bottomY,unsigned width,unsigned height,unsigned targetWidth,unsigned targetHeight) {
    auto& s=GetContext().Native();
    if (x>targetWidth || width>targetWidth-x || bottomY>targetHeight || height>targetHeight-bottomY)
        return s.Fail("Invalid native Metal clip rectangle");
    s.clip={x,targetHeight-bottomY-height,width,height};
    return true;
}
}
