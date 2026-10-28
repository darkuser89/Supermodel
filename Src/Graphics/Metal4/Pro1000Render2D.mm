// Native scroll-layer drawing, preserving the existing Pro-1000 mixer interface.
#include "Graphics/Pro1000Render2D.h"
#include "Native.h"
#include <algorithm>
#include <cstdint>
using namespace SupermodelMetal4;

struct CPro1000Render2D::Native {
    id<MTLRenderPipelineState> pipeline;
    MTLPixelFormat format=MTLPixelFormatInvalid;
};
CPro1000Render2D::CPro1000Render2D() : m_native(std::make_unique<Native>()) {}
CPro1000Render2D::~CPro1000Render2D() = default;

bool CPro1000Render2D::LayerEnabled() const {return (m_scroll&0x03000000)!=0;}
bool CPro1000Render2D::IsBackground() const {return (m_scroll&0x04000000)!=0;}
void CPro1000Render2D::BeginFrame() {}
void CPro1000Render2D::PreRenderFrame() {}
void CPro1000Render2D::EndFrame() {}
void CPro1000Render2D::SetScrollRegister(uint32_t value) {m_scroll=value;}

void CPro1000Render2D::FillLayer() {
    @autoreleasepool {

    auto& s=GetContext().Native();
    auto target=s.colourTarget?s.colourTarget:s.drawable.texture;
    if(!target) {s.Fail("Missing native Pro1000 mixer target");return;}
    if(m_native->format!=target.pixelFormat) {
        m_native->format=target.pixelFormat;
        m_native->pipeline=MakePipeline(s,"surface_vertex","solid_fragment",false,0,false,target.pixelFormat);
    }
    auto pipeline=m_native->pipeline;
    if(!pipeline)return;
    SurfaceUniforms u={};
    u.colour={float((m_scroll>>16)&255)/255,float((m_scroll>>8)&255)/255,float(m_scroll&255)/255,1};
    auto args=MakeArguments(s,nil,&u,sizeof(u),0);if(!args)return;
    // A window resize can change the drawable before the emulated viewport is
    // reconfigured. Clip in signed coordinates so a short target cannot wrap Y.
    int64_t left=m_xOffset,top=int64_t(target.height)-int64_t(m_yOffset)-int64_t(m_yPixels);
    int64_t right=left+m_xPixels,bottom=top+m_yPixels;
    int64_t x0=std::clamp(left,int64_t(0),int64_t(target.width));
    int64_t y0=std::clamp(top,int64_t(0),int64_t(target.height));
    int64_t x1=std::clamp(right,int64_t(0),int64_t(target.width));
    int64_t y1=std::clamp(bottom,int64_t(0),int64_t(target.height));
    if(x1<=x0 || y1<=y0)return;
    auto e=BeginSurfacePass(s,target,false,MTLViewport{double(x0),double(y0),double(x1-x0),double(y1-y0),0,1},
        MTLScissorRect{NSUInteger(x0),NSUInteger(y0),NSUInteger(x1-x0),NSUInteger(y1-y0)});
    if(!e)return;
    [e setRenderPipelineState:pipeline];s.Use(pipeline);
    [e setArgumentTable:args atStages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];

    }
}

void CPro1000Render2D::RenderFrameBottom() {
    @autoreleasepool {

    auto& s=GetContext().Native();auto target=s.colourTarget?s.colourTarget:s.drawable.texture;
    auto e=BeginSurfacePass(s,target,true,MTLViewport{0,0,double(target.width),double(target.height),0,1},
        MTLScissorRect{0,0,target.width,target.height});
    if(e)[e endEncoding];
    if(LayerEnabled() && IsBackground())FillLayer();

    }
}
void CPro1000Render2D::RenderFrameTop() {
    @autoreleasepool {
if(LayerEnabled() && !IsBackground())FillLayer();
    }
}
Result CPro1000Render2D::Init(unsigned xOffset,unsigned yOffset,unsigned xRes,unsigned yRes,
    unsigned totalXRes,unsigned totalYRes,unsigned aaTarget,UpscaleMode) {
    m_xOffset=xOffset;m_yOffset=yOffset;m_xPixels=xRes;m_yPixels=yRes;
    m_totalXPixels=totalXRes;m_totalYPixels=totalYRes;m_aaTarget=aaTarget;
    return GetContext().Native().initialized?Result::OKAY:Result::FAIL;
}
