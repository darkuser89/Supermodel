#pragma once
struct ImDrawData;
namespace SupermodelMetal4 {
bool InitializeGui();
bool RenderGui(ImDrawData* data,const float clearColour[4]);
void ShutdownGui();
}
