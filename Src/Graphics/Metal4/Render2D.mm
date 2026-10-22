// Native Metal implementation of the existing tile-layer renderer interface.
// Copyright 2003-2026 The Supermodel Team. GPL-3.0-or-later.
#include "Graphics/Render2D.h"
#include "Native.h"
#include <algorithm>
#include <cmath>

using namespace SupermodelMetal4;

struct CRender2D::Native {
    bool referenceRendering=std::getenv("SUPERMODEL_REFERENCE_RENDERING")!=nullptr;
    id<MTLTexture> textures[3][2];
    id<MTLRenderPipelineState> pipeline;
    MTLPixelFormat format=MTLPixelFormatInvalid;
    bool Draw(CRender2D& owner,unsigned layer) {
        auto& s=GetContext().Native();
        auto target=s.colourTarget?s.colourTarget:s.drawable.texture;
        if (!target) return s.Fail("Missing native tile mixer target");
        if (format!=target.pixelFormat) {
            format=target.pixelFormat;
            pipeline=MakePipeline(s,"surface_vertex","tile_fragment",false,0,true,format);
            if (!pipeline) return false;
        }
        bool wide=layer==0 && owner.m_config["WideBackground"].ValueAs<bool>();
        double x=wide?0:double(owner.m_xOffset)-owner.m_correction;
        double bottom=wide?0:double(owner.m_yOffset)+owner.m_correction;
        double w=wide?owner.m_totalXPixels:owner.m_xPixels;
        double h=wide?owner.m_totalYPixels:owner.m_yPixels;
        MTLViewport viewport={x,double(target.height)-bottom-h,w,h,0,1};
        SurfaceUniforms u={};u.upscaleMode=unsigned(owner.m_upscaleMode);
        auto tex=textures[s.frameIndex][layer];
        auto args=MakeArguments(s,nil,&u,sizeof(u),0,tex);
        if (!args) return false;
        auto e=BeginSurfacePass(s,target,layer==0,viewport,s.clip);
        if (!e) return false;
        // No tile data yet means clear the background, not sample uninitialized memory.
        if (tex) {
            [e setRenderPipelineState:pipeline];s.Use(pipeline);
            [e setArgumentTable:args atStages:MTLRenderStageFragment];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [e endEncoding];return true;
    }
};

CRender2D::CRender2D(const Util::Config::Node& config) : m_config(config),m_native(std::make_unique<Native>()) {}
CRender2D::~CRender2D() = default;
void CRender2D::BeginFrame() {}
void CRender2D::EndFrame() {}
void CRender2D::WriteVRAM(unsigned,uint32_t) {}
void CRender2D::AttachRegisters(const uint32_t*) {}
void CRender2D::AttachPalette(const uint32_t* [2]) {}
void CRender2D::AttachVRAM(const uint8_t*) {}

void CRender2D::AttachDrawBuffers(std::shared_ptr<TileGenBuffer> bottom,std::shared_ptr<TileGenBuffer> top) {
    m_drawBuffers[0]=std::move(bottom);m_drawBuffers[1]=std::move(top);
}

Result CRender2D::Init(unsigned xOffset,unsigned yOffset,unsigned xRes,unsigned yRes,
    unsigned totalXRes,unsigned totalYRes,unsigned aaTarget,UpscaleMode upscaleMode) {
    m_xOffset=xOffset;m_yOffset=yOffset;m_xPixels=xRes;m_yPixels=yRes;
    m_totalXPixels=totalXRes;m_totalYPixels=totalYRes;m_aaTarget=aaTarget;
    m_correction=unsigned((yRes/384.0)*2.0+0.5);
    m_upscaleMode=xRes==496 && yRes==384?UpscaleMode::Nearest:upscaleMode;
    return GetContext().Native().initialized?Result::OKAY:Result::FAIL;
}

void CRender2D::PreRenderFrame() {
    @autoreleasepool {

    auto& s=GetContext().Native();
    if (!s.recording) {s.Fail("Tile upload outside a native Metal 4 frame");return;}
    // An opaque top tile plane completely hides the 3D mixer within its
    // viewport. Check the actual visible pixels, never a game-specific hint.
    // Bicubic alpha may overshoot; leave that mode on the normal render path.
    s.sceneOccluded=false;
    double left=double(m_xOffset)-m_correction;
    double top=double((s.colourTarget?s.colourTarget:s.drawable.texture).height)
        -double(m_yOffset)-m_correction-m_yPixels;
    bool covers=left<=s.clip.x && top<=s.clip.y &&
        left+m_xPixels>=s.clip.x+s.clip.width && top+m_yPixels>=s.clip.y+s.clip.height;
    if (!m_native->referenceRendering && covers && m_drawBuffers[1] && m_upscaleMode!=UpscaleMode::Bicubic) {
        unsigned minX=496,minY=384,maxX=0,maxY=0;
        for(unsigned y=0;y<384;++y) for(unsigned x=0;x<496;++x)
            if ((m_drawBuffers[1]->data[y*512+x]>>24)!=255) {
                minX=std::min(minX,x);minY=std::min(minY,y);
                maxX=std::max(maxX,x+1);maxY=std::max(maxY,y+1);
            }
        s.sceneOccluded=minX==496;
        if (!s.sceneOccluded) {
            // Include a conservative two-texel filter footprint around every
            // nonopaque source pixel (nearest, bilinear and biquintic alpha).
            double x0=left+std::max(0,int(minX)-2)*double(m_xPixels)/496;
            double y0=top+std::max(0,int(minY)-2)*double(m_yPixels)/384;
            double x1=left+std::min(496u,maxX+2)*double(m_xPixels)/496;
            double y1=top+std::min(384u,maxY+2)*double(m_yPixels)/384;
            NSUInteger l=std::max(s.clip.x,NSUInteger(std::max(0.0,std::floor(x0))));
            NSUInteger t=std::max(s.clip.y,NSUInteger(std::max(0.0,std::floor(y0))));
            NSUInteger r=std::min(s.clip.x+s.clip.width,NSUInteger(std::max(0.0,std::ceil(x1))));
            NSUInteger b=std::min(s.clip.y+s.clip.height,NSUInteger(std::max(0.0,std::ceil(y1))));
            s.sceneOccluded=r<=l || b<=t;
            if (!s.sceneOccluded) s.sceneClip={l,t,r-l,b-t};
        }
    }
    for(unsigned i=0;i<2;++i) {
        if (!m_drawBuffers[i]) continue;
        auto& tex=m_native->textures[s.frameIndex][i];
        if (!tex) {
            auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                width:496 height:384 mipmapped:NO];
            d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
            tex=[s.device newTextureWithDescriptor:d];
            if (!tex) {s.Fail("Cannot allocate native tile texture");return;}
        }
        // Preserve the 512-pixel CPU tile stride; only 496 pixels are visible.
        [tex replaceRegion:MTLRegionMake2D(0,0,496,384) mipmapLevel:0
            withBytes:m_drawBuffers[i]->data bytesPerRow:512*4];
    }

    }
}
void CRender2D::RenderFrameBottom() {
    @autoreleasepool {
m_native->Draw(*this,0);
    }
}
void CRender2D::RenderFrameTop() {
    @autoreleasepool {
m_native->Draw(*this,1);
    }
}
