// Native GPU implementation for Supermodel's current New3D frontend.
// Copyright 2003-2026 The Supermodel Team. GPL-3.0-or-later.
#include "SceneRenderer.h"
#include "Native.h"
#include "Graphics/New3D/Model.h"
#include <algorithm>
#include <cstring>
#include <limits>

namespace SupermodelMetal4 {
namespace {
constexpr unsigned MipLevels = 12;
constexpr unsigned RamVertexBase = 1500000; // Current New3D mesh offset convention.
float4 Vec3(const float* p) { return {p[0],p[1],p[2],0}; }
float4 Vec4(const float* p) { return {p[0],p[1],p[2],p[3]}; }

id<MTLTexture> NewTexture(NativeState& s, MTLPixelFormat format, unsigned w, unsigned h,
    MTLTextureUsage usage, bool shared = false, bool mipmaps = false) {
    auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:mipmaps];
    d.storageMode = shared ? MTLStorageModeShared : MTLStorageModePrivate;
    d.usage = usage;
    auto texture = [s.device newTextureWithDescriptor:d];
    if (!texture) s.Fail("Cannot allocate native Metal 4 texture");
    return texture;
}

void SetViewport(NativeState& s, id<MTL4RenderCommandEncoder> encoder,
    const New3D::Viewport& vp, unsigned height, MTLScissorRect clip) {
    MTLViewport viewport = {double(vp.x),double(int64_t(height)-vp.y-vp.height),
        double(vp.width),double(vp.height),0,1};
    [encoder setViewport:viewport];
    [encoder setScissorRect:clip];
}
}

struct SceneRenderer::State {
    Context& context;
    unsigned width=0, height=0, layer=0;
    bool quads=true;
    bool referenceRendering=std::getenv("SUPERMODEL_REFERENCE_RENDERING")!=nullptr;
    MTLScissorRect clip = {};
    id<MTLTexture> colours[3];
    id<MTLTexture> depth[2];
    id<MTL4RenderCommandEncoder> encoder;
    bool viewportSet=false;
    int lastViewport[4]={};
    MTLScissorRect lastClip={};
    id<MTLDepthStencilState> activeDepth;
    uint32_t activeStencil=~uint32_t(0);
    id<MTLRenderPipelineState> pipelines[2][3][15];
    id<MTLRenderPipelineState> activePipeline;
    id<MTLRenderPipelineState> fogPipeline;
    id<MTLRenderPipelineState> copyPipeline, transPipeline, whitePipeline;
    MTLPixelFormat mixerFormat = MTLPixelFormatInvalid;
    id<MTLDepthStencilState> depthStates[2][2];
    struct TextureMip { std::vector<uint16_t> pixels; uint64_t version=1; };
    TextureMip shadow[2][MipLevels];
    struct Slot {
        id<MTLTexture> banks[2];
        uint64_t versions[2][MipLevels] = {};
        id<MTLBuffer> rom, ram;
        size_t uploadedRomCount=0;
        uint64_t romGeneration=0;
    };
    std::array<Slot,3> slots;
    size_t romCount=0, ramCount=0;
    uint64_t romGeneration=1;
    explicit State(Context& c) : context(c) {
        for (unsigned page=0;page<2;++page) for (unsigned mip=0;mip<MipLevels;++mip)
            shadow[page][mip].pixels.resize(std::max(1u,2048u>>mip)*std::max(1u,1024u>>mip));
    }
    NativeState& Native() { return context.Native(); }

    bool MakePipelines() {
        auto& s=Native();
        for (unsigned q=0;q<2;++q) for (unsigned l=0;l<3;++l) for (unsigned t=0;t<15;++t) {
            if (pipelines[q][l][t]) continue;
            pipelines[q][l][t]=MakePipeline(s,q?"real3d_quad_vertex":"real3d_triangle_vertex",
                q?"real3d_quad_fragment":"real3d_triangle_fragment",true,l,false,MTLPixelFormatInvalid,false,int(t)-2);
            if (!pipelines[q][l][t]) return false;
        }
        if (!fogPipeline) fogPipeline=MakePipeline(s,"surface_vertex","scroll_fog_fragment",true,0,false,MTLPixelFormatInvalid);
        for (unsigned greater=0;greater<2;++greater) for (unsigned decal=0;decal<2;++decal) {
            if (depthStates[greater][decal]) continue;
            auto d=[MTLDepthStencilDescriptor new];
            d.depthCompareFunction=greater?MTLCompareFunctionGreater:MTLCompareFunctionGreaterEqual;
            d.depthWriteEnabled=YES;
            auto stencil=[MTLStencilDescriptor new];
            stencil.stencilCompareFunction=decal?MTLCompareFunctionEqual:MTLCompareFunctionAlways;
            stencil.readMask=decal?0x7F:0x80;
            stencil.writeMask=decal?0x7F:0x80;
            stencil.stencilFailureOperation=MTLStencilOperationKeep;
            stencil.depthFailureOperation=MTLStencilOperationKeep;
            stencil.depthStencilPassOperation=decal?MTLStencilOperationIncrementClamp:MTLStencilOperationReplace;
            d.frontFaceStencil=stencil;
            d.backFaceStencil=stencil;
            depthStates[greater][decal]=[s.device newDepthStencilStateWithDescriptor:d];
            if (!depthStates[greater][decal]) return s.Fail("Cannot allocate Metal 4 depth/stencil state");
        }
        return fogPipeline!=nil;
    }

    bool UploadBuffer(id<MTLBuffer> __strong& buffer,const void* data,size_t bytes) {
        auto& s=Native();
        if (bytes && !data) return s.Fail("Missing New3D vertex data");
        if (!buffer || buffer.length<std::max<size_t>(bytes,4))
            buffer=[s.device newBufferWithLength:std::max<size_t>(bytes,4) options:MTLResourceStorageModeShared];
        if (!buffer) return s.Fail("Cannot allocate native New3D vertex buffer");
        if (bytes) std::memcpy(buffer.contents,data,bytes);
        s.Use(buffer);
        return true;
    }

    bool UploadRom(Slot& slot,const New3D::FVertex* data,size_t count) {
        auto& s=Native();
        size_t bytes=count*sizeof(*data);
        if (bytes && !data) return s.Fail("Missing New3D ROM vertices");
        size_t previous=slot.romGeneration==romGeneration && slot.uploadedRomCount<=count
            ? slot.uploadedRomCount:0;
        if (!slot.rom || slot.rom.length<std::max<size_t>(bytes,4)) {
            size_t capacity=std::max<size_t>({bytes,4096,slot.rom.length+slot.rom.length/2});
            slot.rom=[s.device newBufferWithLength:capacity options:MTLResourceStorageModeShared];
            previous=0;
        }
        if (!slot.rom) return s.Fail("Cannot allocate native ROM vertex cache");
        // The frontend's ROM cache is append-only until explicitly invalidated.
        // A completed slot needs only the vertices added since its previous use.
        if (count>previous) std::memcpy(static_cast<uint8_t*>(slot.rom.contents)+previous*sizeof(*data),
            data+previous,(count-previous)*sizeof(*data));
        slot.uploadedRomCount=count;slot.romGeneration=romGeneration;
        s.Use(slot.rom);
        return true;
    }

    MTL4RenderPassDescriptor* ScenePass(bool clearColour, id<MTLTexture> z=nil, bool clearDepth=false,unsigned outputLayer=0) {
        auto& s=Native();
        auto d=[MTL4RenderPassDescriptor new];
        for (unsigned i=0;i<3;++i) {
            // Transparency writes only its own target. Attaching the two
            // write-masked targets would still load/store their tile contents.
            if (outputLayer && outputLayer!=i) continue;
            d.colorAttachments[i].texture=colours[i];
            d.colorAttachments[i].loadAction=clearColour?MTLLoadActionClear:MTLLoadActionLoad;
            d.colorAttachments[i].storeAction=MTLStoreActionStore;
            d.colorAttachments[i].clearColor=MTLClearColorMake(0,0,0,0);
            s.Use(colours[i]);
        }
        if (z) {
            d.depthAttachment.texture=z;
            d.depthAttachment.loadAction=clearDepth?MTLLoadActionClear:MTLLoadActionLoad;
            d.depthAttachment.storeAction=MTLStoreActionStore;
            d.depthAttachment.clearDepth=0;
            d.stencilAttachment.texture=z;
            d.stencilAttachment.loadAction=clearDepth?MTLLoadActionClear:MTLLoadActionLoad;
            d.stencilAttachment.storeAction=MTLStoreActionStore;
            d.stencilAttachment.clearStencil=0;
            s.Use(z);
        }
        return d;
    }

    id<MTL4RenderCommandEncoder> MixerPass() {
        auto& s=Native();
        if (!s.recording) {s.Fail("Metal 4 mixer needs an active frame");return nil;}
        auto target=s.colourTarget?s.colourTarget:s.drawable.texture;
        if (!target) {s.Fail("Missing Metal 4 mixer target");return nil;}
        if (mixerFormat!=target.pixelFormat) {
            mixerFormat=target.pixelFormat;
            copyPipeline=MakePipeline(s,"surface_vertex","copy_fragment",false,0,true,mixerFormat);
            transPipeline=MakePipeline(s,"surface_vertex","transparency_fragment",false,0,true,mixerFormat);
            whitePipeline=MakePipeline(s,"surface_vertex","solid_fragment",false,0,false,mixerFormat);
            if (!copyPipeline || !transPipeline || !whitePipeline) return nil;
        }
        auto d=[MTL4RenderPassDescriptor new];
        d.colorAttachments[0].texture=target;
        d.colorAttachments[0].loadAction=MTLLoadActionLoad;
        d.colorAttachments[0].storeAction=MTLStoreActionStore;
        s.Use(target);
        auto e=[s.Frame().commands renderCommandEncoderWithDescriptor:d];
        if (!e) {s.Fail("Cannot create Metal 4 mixer pass");return nil;}
        Synchronize(e);
        [e setViewport:MTLViewport{0,0,double(width),double(height),0,1}];
        [e setScissorRect:s.clip];
        [e setCullMode:MTLCullModeNone];
        return e;
    }
};

SceneRenderer::SceneRenderer(Context& context) : m_state(std::make_unique<State>(context)) {}
SceneRenderer::~SceneRenderer() { EndLayer(); }
bool SceneRenderer::IsOccluded() const {return m_state->context.Native().sceneOccluded;}
void SceneRenderer::InvalidateRomCache() {++m_state->romGeneration;}

bool SceneRenderer::Resize(unsigned width,unsigned height) {
    @autoreleasepool {

    auto& p=*m_state;auto& s=p.Native();
    if (!s.initialized || !width || !height) return s.Fail("Invalid Metal 4 scene size/context");
    EndLayer();
    // Frame residency ownership keeps replaced targets alive until GPU completion.
    p.width=width;p.height=height;
    for (auto& t:p.colours) {
        t=NewTexture(s,MTLPixelFormatRGBA8Unorm,width,height,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
        if (!t) return false;
    }
    for (auto& t:p.depth) {
        t=NewTexture(s,MTLPixelFormatDepth32Float_Stencil8,width,height,MTLTextureUsageRenderTarget);
        if (!t) return false;
    }
    return p.MakePipelines();

    }
}

bool SceneRenderer::UploadTextures(unsigned page,unsigned level,unsigned x,unsigned y,
    unsigned width,unsigned height,const uint16_t* sheet) {
    @autoreleasepool {

    auto& p=*m_state;
    static constexpr unsigned baseX[]={0,1024,1536,1792,1920,1984,2016,2032,2040,2044,2046,2047};
    static constexpr unsigned baseY[]={0,512,768,896,960,992,1008,1016,1020,1022,1023,1023};
    if (page>1 || level>=MipLevels || !sheet || x<baseX[level] || y<baseY[level])
        return p.Native().Fail("Invalid native Real3D texture upload");
    unsigned w=std::max(1u,2048u>>level),h=std::max(1u,1024u>>level);
    unsigned subX=x-baseX[level],subY=y-baseY[level];
    if (subX>w || width>w-subX || subY>h || height>h-subY || x>2048 || width>2048-x || y>1024 || height>1024-y)
        return p.Native().Fail("Real3D texture upload exceeds its mip/sheet bounds");
    auto& mip=p.shadow[page][level];
    for (unsigned row=0;row<height;++row)
        std::memcpy(mip.pixels.data()+(subY+row)*w+subX,sheet+(y+row)*2048+x,width*sizeof(uint16_t));
    ++mip.version;
    return true;

    }
}

bool SceneRenderer::BeginScene(const New3D::FVertex* rom,size_t romCount,
    const New3D::FVertex* ram,size_t ramCount,bool quads,bool allowOcclusion) {
    @autoreleasepool {

    static_assert(sizeof(New3D::FVertex)==60,"MSL vertex pulling requires the current New3D FVertex ABI");
    static_assert(offsetof(New3D::FVertex,faceNormal)==40 && offsetof(New3D::FVertex,faceColour)==52 &&
        offsetof(New3D::FVertex,textureNP)==56,"MSL full-vertex attribute offsets changed");
    auto& p=*m_state;auto& s=p.Native();
    if (!s.recording || !p.width || !p.height) return s.Fail("New3D needs an active Metal 4 frame");
    auto& slot=p.slots[s.frameIndex];
    p.clip=allowOcclusion?s.sceneClip:s.clip;
    p.quads=quads;p.romCount=romCount;p.ramCount=ramCount;
    if (!p.UploadRom(slot,rom,romCount) || !p.UploadBuffer(slot.ram,ram,ramCount*sizeof(*ram))) return false;
    for (unsigned page=0;page<2;++page) {
        if (!slot.banks[page]) slot.banks[page]=NewTexture(s,MTLPixelFormatR16Uint,2048,1024,MTLTextureUsageShaderRead,true,true);
        if (!slot.banks[page]) return false;
        for (unsigned mip=0;mip<MipLevels;++mip) {
            if (slot.versions[page][mip]==p.shadow[page][mip].version) continue;
            unsigned w=std::max(1u,2048u>>mip),h=std::max(1u,1024u>>mip);
            [slot.banks[page] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:mip
                withBytes:p.shadow[page][mip].pixels.data() bytesPerRow:w*sizeof(uint16_t)];
            slot.versions[page][mip]=p.shadow[page][mip].version;
        }
        s.Use(slot.banks[page]);
    }
    auto e=[s.Frame().commands renderCommandEncoderWithDescriptor:p.ScenePass(true)];
    if (!e) return s.Fail("Cannot clear native Real3D layers");
    Synchronize(e);[e endEncoding];
    return true;

    }
}

bool SceneRenderer::BeginLayer(unsigned layer,bool clearDepth) {
    @autoreleasepool {

    EndLayer();auto& p=*m_state;auto& s=p.Native();
    if (!s.recording) return s.Fail("Real3D layer needs an active Metal 4 frame");
    if (layer>2) return s.Fail("Invalid Real3D layer");
    s.Timestamp("before scene layer");
    p.layer=layer;
    p.encoder=[s.Frame().commands renderCommandEncoderWithDescriptor:p.ScenePass(false,p.depth[layer==2?1:0],clearDepth,layer)];
    if (!p.encoder) return s.Fail("Cannot create native Real3D render pass");
    Synchronize(p.encoder);
    [p.encoder setCullMode:MTLCullModeNone];
    p.activePipeline=nil;
    [p.encoder setArgumentTable:s.Frame().arguments atStages:MTLRenderStageVertex|MTLRenderStageFragment];
    p.viewportSet=false;p.activeDepth=nil;p.activeStencil=~uint32_t(0);

    return true;

    }
}

bool SceneRenderer::Draw(const New3D::Viewport& vp,const New3D::Model& model,const New3D::Mesh& mesh) {
    @autoreleasepool {

    auto& p=*m_state;auto& s=p.Native();
    if (!p.encoder) return s.Fail("Real3D draw outside a Metal 4 layer");
    if (vp.width<=0 || vp.height<=0) return true;
    DrawUniforms u={};
    std::memcpy(&u.modelMat,model.modelMat,sizeof(u.modelMat));
    std::memcpy(&u.projMat,vp.projectionMatrix.currentMatrix,sizeof(u.projMat));
    u.targetSize={float(p.width),float(p.height)};
    u.modelScale=model.scale;u.nodeAlpha=model.alpha;u.cota=vp.cota;
    u.fogColour=Vec3(vp.fogColour);u.spotEllipse=Vec4(vp.spotEllipse);
    u.spotColor=Vec3(vp.spotColor);u.spotFogColor=Vec3(vp.spotFogColor);
    u.spotRange={vp.spotRange[0],vp.spotRange[1]};
    u.lighting[0]=Vec3(vp.lightingParams);u.lighting[1]=Vec3(vp.lightingParams+3);
    u.fogDensity=vp.fogDensity;u.fogStart=vp.fogStart;u.fogAttenuation=vp.fogAttenuation;u.fogAmbient=vp.fogAmbient;
    u.sunClamp=vp.sunClamp;u.intensityClamp=vp.intensityClamp;u.step15Luminous=vp.step15Luminous;
    u.baseTexInfo={mesh.x+model.textureOffsetX,mesh.y+model.textureOffsetY,mesh.width,mesh.height};
    u.textureWrapMode={int(mesh.wrapModeU),int(mesh.wrapModeV)};
    u.textureEnabled=mesh.textured;u.microTexture=mesh.microTexture;u.microTextureMinLOD=mesh.microTextureMinLOD;
    u.microTextureID=mesh.microTextureID;u.texturePage=mesh.page^model.page;u.baseTexType=mesh.format;
    u.textureInverted=mesh.inverted;u.textureAlpha=mesh.textureAlpha;u.alphaTest=mesh.alphaTest;
    u.discardAlpha=p.layer==0;u.colourLayer=p.layer;
    u.fogIntensity=mesh.fogIntensity;u.lightEnabled=mesh.lighting;u.shininess=mesh.shininess;
    u.specularEnabled=mesh.specular;u.specularValue=mesh.specularValue;
    u.fixedShading=mesh.fixedShading;u.smoothShading=mesh.smoothShading;u.translatorMap=mesh.translatorMap;
    u.layerDepthBias=mesh.layered?1.0f+1.0f/512.0f:1.0f;
    unsigned variant=u.textureEnabled?(u.baseTexType<12?u.baseTexType+2:0):1;
    if (u.textureEnabled && u.baseTexType==0 && !u.textureAlpha && !u.alphaTest &&
        !u.microTexture && u.lightEnabled && !u.specularEnabled && !u.fixedShading) variant=14;
    const auto& projection=u.projMat;
    bool standardProjection=projection.columns[0].z==0 && projection.columns[0].w==0 &&
        projection.columns[1].z==0 && projection.columns[1].w==0 &&
        projection.columns[2].z==0 && projection.columns[2].w==-1 && projection.columns[3].w==0;
    bool powerOfTwoTexture=!u.textureEnabled || (u.baseTexInfo.x>=0 && u.baseTexInfo.y>=0 && u.baseTexInfo.z>0 && u.baseTexInfo.w>0 &&
        !(u.baseTexInfo.z&(u.baseTexInfo.z-1)) && !(u.baseTexInfo.w&(u.baseTexInfo.w-1)));
    if (p.referenceRendering || !standardProjection || !powerOfTwoTexture) variant=0;
    auto pipeline=p.pipelines[p.quads?1:0][p.layer][variant];
    if (p.activePipeline!=pipeline) {
        [p.encoder setRenderPipelineState:pipeline];s.Use(pipeline);p.activePipeline=pipeline;
    }
    auto& slot=p.slots[s.frameIndex];
    if (mesh.vboOffset<0 || mesh.vertexCount<0) return s.Fail("Negative New3D mesh range");
    bool ram=model.dynamic;
    if (ram && unsigned(mesh.vboOffset)<RamVertexBase) return s.Fail("Invalid dynamic New3D mesh offset");
    unsigned offset=unsigned(mesh.vboOffset)-(ram?RamVertexBase:0);
    size_t count=ram?p.ramCount:p.romCount;
    if (offset>count || size_t(mesh.vertexCount)>count-offset || mesh.vertexCount%(p.quads?4:3))
        return s.Fail("New3D mesh range exceeds uploaded native geometry");
    u.vertexOffset=offset;
    auto args=MakeArguments(s,ram?slot.ram:slot.rom,&u,sizeof(u),1,slot.banks[0],slot.banks[1]);
    if (!args) return false;
    if (!p.viewportSet || p.lastViewport[0]!=vp.x || p.lastViewport[1]!=vp.y ||
        p.lastViewport[2]!=vp.width || p.lastViewport[3]!=vp.height ||
        p.lastClip.x!=p.clip.x || p.lastClip.y!=p.clip.y ||
        p.lastClip.width!=p.clip.width || p.lastClip.height!=p.clip.height) {
        SetViewport(s,p.encoder,vp,p.height,p.clip);p.viewportSet=true;
        p.lastViewport[0]=vp.x;p.lastViewport[1]=vp.y;p.lastViewport[2]=vp.width;p.lastViewport[3]=vp.height;
        p.lastClip=p.clip;
    }
    auto depth=p.depthStates[p.layer?1:0][mesh.layered?1:0];
    if (p.activeDepth!=depth) {
        [p.encoder setDepthStencilState:depth];s.Retain(depth);p.activeDepth=depth;
    }
    uint32_t stencil=mesh.layered?0:(mesh.noLosReturn?0x80:0);
    if (p.activeStencil!=stencil) {[p.encoder setStencilReferenceValue:stencil];p.activeStencil=stencil;}
    // The encoder keeps this slot's table bound; each draw snapshots its new
    // addresses without rebinding the same table or revalidating fixed state.
    NSUInteger vertices=p.quads?NSUInteger(mesh.vertexCount/4)*6:mesh.vertexCount;
    [p.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices];
    return true;

    }
}

void SceneRenderer::EndLayer() {
    @autoreleasepool {
 auto& p=*m_state;if(p.encoder){[p.encoder endEncoding];p.encoder=nil;p.Native().Timestamp(p.layer==0?"opaque":p.layer==1?"trans1":"trans2");} 
    }
}

bool SceneRenderer::StoreDepth() {
    @autoreleasepool {

    EndLayer();auto& p=*m_state;auto& s=p.Native();
    if (!s.recording) return s.Fail("Real3D depth copy needs an active Metal 4 frame");
    auto e=[s.Frame().commands computeCommandEncoder];
    if (!e) return s.Fail("Cannot create native depth/stencil copy encoder");
    Synchronize(e);s.Use(p.depth[0]);s.Use(p.depth[1]);
    [e copyFromTexture:p.depth[0] toTexture:p.depth[1]];
    [e endEncoding];return true;

    }
}

bool SceneRenderer::ReadLos(int x,int y,float& depth,uint8_t& stencil) {
    @autoreleasepool {

    EndLayer();auto& p=*m_state;auto& s=p.Native();
    if (!s.recording) return s.Fail("Real3D visibility readback needs an active Metal 4 frame");
    // Off-screen LOS coordinates do not justify an invalid GPU copy or a fatal
    // device error. The frontend keeps its reset/default result for this layer.
    if (x<0 || y<0 || unsigned(x)>=p.width || unsigned(y)>=p.height) return false;
    auto data=[s.device newBufferWithLength:512 options:MTLResourceStorageModeShared];
    if (!data) return s.Fail("Cannot allocate Real3D visibility readback");
    auto e=[s.Frame().commands computeCommandEncoder];
    if (!e) return s.Fail("Cannot create Real3D visibility copy encoder");
    Synchronize(e);s.Use(data);s.Use(p.depth[1]);
    MTLOrigin origin=MTLOriginMake(x,p.height-1-y,0);
    [e copyFromTexture:p.depth[1] sourceSlice:0 sourceLevel:0 sourceOrigin:origin sourceSize:MTLSizeMake(1,1,1)
        toBuffer:data destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:0 options:MTLBlitOptionDepthFromDepthStencil];
    [e copyFromTexture:p.depth[1] sourceSlice:0 sourceLevel:0 sourceOrigin:origin sourceSize:MTLSizeMake(1,1,1)
        toBuffer:data destinationOffset:256 destinationBytesPerRow:256 destinationBytesPerImage:0 options:MTLBlitOptionStencilFromDepthStencil];
    [e endEncoding];
    if (!p.context.Flush()) return false;
    std::memcpy(&depth,data.contents,sizeof(depth));
    stencil=static_cast<const uint8_t*>(data.contents)[256];
    // Caller preserves the current New3D NearPlane conversion and status bit.
    return true;

    }
}

bool SceneRenderer::Fog(const New3D::Viewport& vp,const float colour[4],float attenuation,
    float ambient,const float spotColour[3],const float ellipse[4]) {
    @autoreleasepool {

    EndLayer();auto& p=*m_state;auto& s=p.Native();
    if (!s.recording) return s.Fail("Real3D fog needs an active Metal 4 frame");
    if (vp.width<=0 || vp.height<=0) return true;
    SurfaceUniforms u={};u.colour=Vec4(colour);u.spotEllipse=Vec4(ellipse);u.spotFogColor=Vec3(spotColour);
    u.fogAttenuation=attenuation;u.fogAmbient=ambient;u.targetSize={float(p.width),float(p.height)};
    auto args=MakeArguments(s,nil,&u,sizeof(u),0);if(!args)return false;
    auto e=[s.Frame().commands renderCommandEncoderWithDescriptor:p.ScenePass(false)];
    if (!e) return s.Fail("Cannot create Real3D fog pass");
    Synchronize(e);SetViewport(s,e,vp,p.height,p.clip);
    [e setRenderPipelineState:p.fogPipeline];
    s.Use(p.fogPipeline);
    [e setArgumentTable:args atStages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];return true;

    }
}

bool SceneRenderer::Composite() {
    @autoreleasepool {

    EndLayer();auto& p=*m_state;auto& s=p.Native();
    auto e=p.MixerPass();if(!e)return false;
    auto base=MakeArguments(s,nil,nullptr,0,0,p.colours[0]);
    if (!base) {[e endEncoding];return false;}
    [e setRenderPipelineState:p.copyPipeline];[e setArgumentTable:base atStages:MTLRenderStageFragment];
    s.Use(p.copyPipeline);s.Use(p.transPipeline);
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    auto trans=MakeArguments(s,nil,nullptr,0,0,p.colours[1],p.colours[2]);
    if (!trans) {[e endEncoding];return false;}
    [e setRenderPipelineState:p.transPipeline];[e setArgumentTable:trans atStages:MTLRenderStageFragment];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];return true;

    }
}

bool SceneRenderer::WhiteFlash() {
    @autoreleasepool {

    EndLayer();auto& p=*m_state;auto& s=p.Native();
    SurfaceUniforms u={};u.colour={1,1,1,1};
    auto args=MakeArguments(s,nil,&u,sizeof(u),0);if(!args)return false;
    auto e=p.MixerPass();if(!e)return false;
    [e setRenderPipelineState:p.whitePipeline];[e setArgumentTable:args atStages:MTLRenderStageFragment];
    s.Use(p.whitePipeline);
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];return true;

    }
}
}
