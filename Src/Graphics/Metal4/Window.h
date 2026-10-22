// SDL window integration for native Metal 4. GPL-3.0-or-later.
#pragma once
struct SDL_Window;
namespace SupermodelMetal4 {
bool PrepareAppRuntimeDirectory();
bool AttachWindow(SDL_Window* window);
void SetGameActive(bool active);
void DetachWindow();
void DrawableSize(SDL_Window* window,int& width,int& height);
bool ResizeWindow(SDL_Window* window,bool vsync);
bool SetClip(unsigned x,unsigned bottomY,unsigned width,unsigned height,unsigned targetWidth,unsigned targetHeight);
}
