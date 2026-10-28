// Native Metal 4 ImGui renderer. The bundled ImGui sources remain unchanged.
#include "GuiRenderer.h"
#include "Native.h"
#include "Pkgs/imgui/imgui.h"
#include <algorithm>
#include <cmath>
#include <map>

namespace SupermodelMetal4 {
namespace {
struct GuiState {
    id<MTLRenderPipelineState> pipeline;
    std::map<ImTextureID,id<MTLTexture>> textures;
    ImTextureID nextID=1;
};
std::unique_ptr<GuiState> gui;

bool UpdateTexture(ImTextureData* texture) {
    auto& s=GetContext().Native();
    if(texture->Status==ImTextureStatus_WantDestroy && texture->UnusedFrames>0) {
        gui->textures.erase(texture->TexID);
        texture->SetTexID(ImTextureID_Invalid);texture->SetStatus(ImTextureStatus_Destroyed);return true;
    }
    if(texture->Status!=ImTextureStatus_WantCreate && texture->Status!=ImTextureStatus_WantUpdates)return true;
    if(texture->Width<=0 || texture->Height<=0 || !texture->GetPixels())return s.Fail("Invalid native ImGui atlas");
    auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:texture->Width height:texture->Height mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead;
    auto native=[s.device newTextureWithDescriptor:descriptor];
    if(!native)return s.Fail("Cannot allocate native ImGui atlas");
    const void* pixels=texture->GetPixels();
    std::vector<uint8_t> rgba;
    if(texture->Format==ImTextureFormat_Alpha8) {
        rgba.resize(size_t(texture->Width)*texture->Height*4,255);
        for(size_t i=0;i<rgba.size()/4;++i)rgba[i*4+3]=static_cast<const uint8_t*>(pixels)[i];
        pixels=rgba.data();
    } else if(texture->Format!=ImTextureFormat_RGBA32)return s.Fail("Unsupported native ImGui atlas format");
    // Copy-on-write keeps previous frames' atlas contents immutable while the
    // dynamic font atlas grows. Draw residency owns each prior texture version.
    [native replaceRegion:MTLRegionMake2D(0,0,texture->Width,texture->Height) mipmapLevel:0
        withBytes:pixels bytesPerRow:size_t(texture->Width)*4];
    ImTextureID id=texture->Status==ImTextureStatus_WantCreate?gui->nextID++:texture->TexID;
    gui->textures[id]=native;texture->SetTexID(id);texture->SetStatus(ImTextureStatus_OK);
    return true;
}
}

bool InitializeGui() {
    @autoreleasepool {

    auto& s=GetContext().Native();
    if(gui)return s.Fail("Metal 4 ImGui backend already initialized");
    gui=std::make_unique<GuiState>();
    gui->pipeline=MakePipeline(s,"gui_vertex","overlay_fragment",false,0,true,MTLPixelFormatBGRA8Unorm,true);
    if(!gui->pipeline){gui.reset();return false;}
    auto& io=ImGui::GetIO();
    io.BackendRendererUserData=gui.get();io.BackendRendererName="Supermodel_Metal4";
    io.BackendFlags|=ImGuiBackendFlags_RendererHasTextures|ImGuiBackendFlags_RendererHasVtxOffset;
    auto& platform=ImGui::GetPlatformIO();platform.Renderer_TextureMaxWidth=16384;platform.Renderer_TextureMaxHeight=16384;
    return true;

    }
}

bool RenderGui(ImDrawData* data,const float clearColour[4]) {
    @autoreleasepool {

    static_assert(sizeof(ImDrawVert)==20 && offsetof(ImDrawVert,pos)==0 && offsetof(ImDrawVert,uv)==8 &&
        offsetof(ImDrawVert,col)==16,"MSL ImGui vertex layout changed");
    auto& context=GetContext();auto& s=context.Native();
    if(!gui || !data)return s.Fail("Missing native ImGui draw data");
    if(data->Textures)for(auto* texture:*data->Textures)if(!UpdateTexture(texture))return false;
    int width=int(data->DisplaySize.x*data->FramebufferScale.x),height=int(data->DisplaySize.y*data->FramebufferScale.y);
    if(width<=0 || height<=0)return true;
    if((s.width!=unsigned(width) || s.height!=unsigned(height)) && !context.Resize(width,height,true))return false;
    if(!context.BeginFrame())return context.Error().empty();
    OverlayUniforms u={};u.colour={1,1,1,1};u.textured=1;
    float l=data->DisplayPos.x,r=l+data->DisplaySize.x,t=data->DisplayPos.y,b=t+data->DisplaySize.y;
    u.projection.columns[0]={2/(r-l),0,0,0};u.projection.columns[1]={0,2/(t-b),0,0};
    u.projection.columns[2]={0,0,-1,0};u.projection.columns[3]={(r+l)/(l-r),(t+b)/(b-t),0,1};
    auto e=BeginSurfacePass(s,s.drawable.texture,true,MTLViewport{0,0,double(width),double(height),0,1},
        MTLScissorRect{0,0,NSUInteger(width),NSUInteger(height)},
        MTLClearColorMake(clearColour[0]*clearColour[3],clearColour[1]*clearColour[3],clearColour[2]*clearColour[3],clearColour[3]));
    if(!e)return false;
    s.Use(gui->pipeline);
    bool ok=true;
    for(const auto* list:data->CmdLists) {
        if(list->VtxBuffer.empty() || list->IdxBuffer.empty())continue;
        auto vertices=[s.device newBufferWithBytes:list->VtxBuffer.Data length:list->VtxBuffer.Size*sizeof(ImDrawVert)
            options:MTLResourceStorageModeShared];
        auto indices=[s.device newBufferWithBytes:list->IdxBuffer.Data length:list->IdxBuffer.Size*sizeof(ImDrawIdx)
            options:MTLResourceStorageModeShared];
        if(!vertices || !indices){ok=s.Fail("Cannot allocate native ImGui draw buffers");break;}
        s.Use(indices);
        for(const auto& draw:list->CmdBuffer) {
            if(draw.UserCallback) {
                if(draw.UserCallback!=ImDrawCallback_ResetRenderState)draw.UserCallback(list,&draw);
                continue;
            }
            float x0=std::clamp((draw.ClipRect.x-data->DisplayPos.x)*data->FramebufferScale.x,0.0f,float(width));
            float y0=std::clamp((draw.ClipRect.y-data->DisplayPos.y)*data->FramebufferScale.y,0.0f,float(height));
            float x1=std::clamp((draw.ClipRect.z-data->DisplayPos.x)*data->FramebufferScale.x,0.0f,float(width));
            float y1=std::clamp((draw.ClipRect.w-data->DisplayPos.y)*data->FramebufferScale.y,0.0f,float(height));
            if(x1<=x0 || y1<=y0)continue;
            auto tex=gui->textures.find(draw.GetTexID());
            if(tex==gui->textures.end()){ok=s.Fail("Unregistered native ImGui texture");break;}
            if(draw.IdxOffset>unsigned(list->IdxBuffer.Size) || draw.ElemCount>unsigned(list->IdxBuffer.Size)-draw.IdxOffset) {
                ok=s.Fail("ImGui index range exceeds its native buffer");break;
            }
            auto args=MakeArguments(s,vertices,&u,sizeof(u),1,tex->second);if(!args){ok=false;break;}
            [e setRenderPipelineState:gui->pipeline];
            [e setViewport:MTLViewport{0,0,double(width),double(height),0,1}];
            // Cover every framebuffer pixel touched by a fractional clip edge.
            NSUInteger left=NSUInteger(std::floor(x0)),top=NSUInteger(std::floor(y0));
            NSUInteger right=NSUInteger(std::ceil(x1)),bottom=NSUInteger(std::ceil(y1));
            [e setScissorRect:MTLScissorRect{left,top,right-left,bottom-top}];
            [e setArgumentTable:args atStages:MTLRenderStageVertex|MTLRenderStageFragment];
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:draw.ElemCount
                indexType:sizeof(ImDrawIdx)==2?MTLIndexTypeUInt16:MTLIndexTypeUInt32
                indexBuffer:indices.gpuAddress+draw.IdxOffset*sizeof(ImDrawIdx) indexBufferLength:draw.ElemCount*sizeof(ImDrawIdx)
                instanceCount:1 baseVertex:draw.VtxOffset baseInstance:0];
        }
        if(!ok)break;
    }
    [e endEncoding];
    return context.SubmitFrame() && ok;

    }
}

void ShutdownGui() {
    if(!gui)return;
    for(auto* texture:ImGui::GetPlatformIO().Textures) {
        if(gui->textures.count(texture->TexID)) {
            texture->SetTexID(ImTextureID_Invalid);texture->SetStatus(ImTextureStatus_Destroyed);
        }
    }
    auto& io=ImGui::GetIO();io.BackendRendererUserData=nullptr;io.BackendRendererName=nullptr;
    io.BackendFlags&=~(ImGuiBackendFlags_RendererHasTextures|ImGuiBackendFlags_RendererHasVtxOffset);
    gui.reset();
}
}
