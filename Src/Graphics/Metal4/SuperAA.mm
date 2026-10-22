// Native supersampling and CRT colour processing, preserving SuperAA semantics.
#include "Graphics/SuperAA.h"
#include "Native.h"
using namespace SupermodelMetal4;

struct SuperAA::Native { id<MTLTexture> target; id<MTLRenderPipelineState> resolve; };
SuperAA::SuperAA(int aaValue,CRTcolor colours) : m_native(std::make_unique<Native>()),
    m_aa(aaValue),m_crtcolors(colours),m_width(0),m_height(0) {}
SuperAA::~SuperAA() {
    auto& s=GetContext().Native();
    if (s.colourTarget==m_native->target) s.colourTarget=nil;
}
unsigned SuperAA::GetTargetID() {return m_aa>1 || m_crtcolors!=CRTcolor::None?1u:0u;}

void SuperAA::Init(int width,int height) {
    @autoreleasepool {

    auto& s=GetContext().Native();
    if (width<=0 || height<=0 || m_aa<1 || width>16384/m_aa || height>16384/m_aa) {
        s.Fail("Invalid native supersampling target size");return;
    }
    m_width=width;m_height=height;
    if (!GetTargetID()) {s.colourTarget=nil;return;}
    auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:width*m_aa height:height*m_aa mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    m_native->target=[s.device newTextureWithDescriptor:d];
    if (!m_native->target) {s.Fail("Cannot allocate native supersampling target");return;}
    m_native->resolve=MakePipeline(s,"surface_vertex","resolve_fragment",false,0,false,MTLPixelFormatBGRA8Unorm);
    s.colourTarget=m_native->target;

    }
}

void SuperAA::Draw() {
    @autoreleasepool {

    if (!GetTargetID()) return;
    auto& s=GetContext().Native();
    if (!m_native->target || !m_native->resolve) {s.Fail("Native supersampling is not initialized");return;}
    SurfaceUniforms u={};u.supersampling=m_aa;u.crtMode=unsigned(m_crtcolors);
    auto args=MakeArguments(s,nil,&u,sizeof(u),0,m_native->target);if(!args)return;
    auto e=BeginSurfacePass(s,s.drawable.texture,false,MTLViewport{0,0,double(m_width),double(m_height),0,1},
        MTLScissorRect{0,0,NSUInteger(m_width),NSUInteger(m_height)});
    if (!e) return;
    [e setRenderPipelineState:m_native->resolve];s.Use(m_native->resolve);
    [e setArgumentTable:args atStages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];

    }
}
