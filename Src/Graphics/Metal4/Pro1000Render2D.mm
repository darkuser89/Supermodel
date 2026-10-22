// Native scroll-layer drawing, preserving the existing Pro-1000 mixer interface.
#include "Graphics/Pro1000Render2D.h"
#include "Native.h"
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
    NSUInteger y=target.height-m_yOffset-m_yPixels;
    auto e=BeginSurfacePass(s,target,false,MTLViewport{double(m_xOffset),double(y),double(m_xPixels),double(m_yPixels),0,1},
        MTLScissorRect{m_xOffset,y,m_xPixels,m_yPixels});
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
    auto e=BeginSurfacePass(s,target,true,MTLViewport{0,0,double(m_totalXPixels),double(m_totalYPixels),0,1},
        MTLScissorRect{0,0,m_totalXPixels,m_totalYPixels});
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
