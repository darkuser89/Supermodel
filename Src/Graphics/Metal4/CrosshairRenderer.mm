#include "CrosshairRenderer.h"
#include "Native.h"
#include <cstring>

namespace SupermodelMetal4 {
struct CrosshairRenderer::State {
    id<MTLTexture> textures[2];
    id<MTLRenderPipelineState> pipelines[2];
};
CrosshairRenderer::CrosshairRenderer() : m_state(std::make_unique<State>()) {}
CrosshairRenderer::~CrosshairRenderer() = default;

bool CrosshairRenderer::Upload(unsigned player,const uint8_t* rgba,unsigned width,unsigned height,size_t pitch) {
    @autoreleasepool {

    auto& s=GetContext().Native();
    if(player>1 || !rgba || !width || !height || pitch<size_t(width)*4)
        return s.Fail("Invalid native crosshair bitmap");
    auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:width height:height mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead;
    auto tex=[s.device newTextureWithDescriptor:descriptor];
    if(!tex)return s.Fail("Cannot allocate native crosshair bitmap");
    [tex replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:rgba bytesPerRow:pitch];
    m_state->textures[player]=tex;return true;

    }
}

bool CrosshairRenderer::Draw(const float* xyz,size_t count,const float* uv,size_t uvCount,const float* matrix,
    const float* colour,bool textured,unsigned player,unsigned x,unsigned y,unsigned width,unsigned height) {
    @autoreleasepool {

    auto& s=GetContext().Native();
    if(player>1 || !xyz || !matrix || !colour || (textured && (!uv || uvCount<count)))
        return s.Fail("Invalid native crosshair geometry");
    if(!width || !height || !count)return true;
    if(!m_state->pipelines[textured])m_state->pipelines[textured]=MakePipeline(s,"overlay_vertex",
        textured?"crosshair_fragment":"overlay_solid_fragment",false,0,textured,MTLPixelFormatBGRA8Unorm);
    auto pipeline=m_state->pipelines[textured];if(!pipeline)return false;
    struct Vertex {float position[4],uv[2],colour[4];};
    static_assert(sizeof(Vertex)==40,"MSL overlay vertex ABI");
    std::vector<Vertex> vertices(count);
    for(size_t i=0;i<count;++i) {
        auto& v=vertices[i];std::memcpy(v.position,xyz+i*3,3*sizeof(float));v.position[3]=1;
        if(textured)std::memcpy(v.uv,uv+i*2,2*sizeof(float));
        for(float& c:v.colour)c=1;
    }
    auto buffer=[s.device newBufferWithBytes:vertices.data() length:vertices.size()*sizeof(Vertex) options:MTLResourceStorageModeShared];
    if(!buffer)return s.Fail("Cannot allocate native crosshair vertices");
    OverlayUniforms u={};std::memcpy(&u.projection,matrix,sizeof(u.projection));u.textured=textured;
    u.colour={colour[0],colour[1],colour[2],colour[3]};
    auto args=MakeArguments(s,buffer,&u,sizeof(u),1,textured?m_state->textures[player]:nil);if(!args)return false;
    auto target=s.drawable.texture;
    auto clip=s.colourTarget?MTLScissorRect{0,0,target.width,target.height}:s.clip;
    auto e=BeginSurfacePass(s,target,false,MTLViewport{double(x),double(target.height)-y-height,double(width),double(height),0,1},clip);
    if(!e)return false;
    [e setRenderPipelineState:pipeline];s.Use(pipeline);
    [e setArgumentTable:args atStages:MTLRenderStageVertex|MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count];
    [e endEncoding];return true;

    }
}
}
