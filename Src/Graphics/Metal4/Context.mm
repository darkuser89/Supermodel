// Supermodel native Metal 4 backend. GPL-3.0-or-later.
#include "Native.h"
#include "Benchmark.h"
#include <cstring>
#include <algorithm>
#include <cstdlib>
#include <cstdio>
#include <numeric>
#include <cmath>

namespace SupermodelMetal4 {
namespace {
constexpr uint64_t GPUWaitMilliseconds = 5000;
}

Context::Context() : m_native(std::make_unique<NativeState>()) {}
Context& GetContext() { static Context context; return context; }
Context::~Context() { Shutdown(); }
NativeState& Context::Native() { return *m_native; }
std::string Context::Error() const { return m_native->feedback->Get(); }
std::string Context::DeviceName() const {return m_native->device?m_native->device.name.UTF8String:"uninitialized";}
bool Context::IsFrameActive() const {return m_native->recording;}

bool Context::Initialize(void* metalLayer, const char* libraryPath) {
    @autoreleasepool {
        auto& s = *m_native;
        if (s.initialized) return s.Fail("Metal 4 context already initialized");
        if (!metalLayer || !libraryPath || !*libraryPath)
            return s.Fail("Metal 4 needs a CAMetalLayer and a compiled shader library");
        s.device = MTLCreateSystemDefaultDevice();
        if (!s.device || !s.device.hasUnifiedMemory ||
            ![s.device supportsFamily:MTLGPUFamilyApple7] ||
            ![s.device supportsFamily:MTLGPUFamilyMetal4])
            return s.Fail("Supermodel Metal 4 requires an Apple Silicon GPU with Metal 4 support");
        NSError* error = nil;
        s.queue = [s.device newMTL4CommandQueue];
        s.compiler = [s.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
        if (!s.queue || !s.compiler) return s.Fail(@"Create Metal 4 command queue/compiler", error);
        s.completed = [s.device newSharedEvent];
        if (!s.completed) return s.Fail("Cannot create Metal 4 completion event");
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:libraryPath]];
        s.library = [s.device newLibraryWithURL:url error:&error];
        if (!s.library) return s.Fail(@"Load native Metal shader library", error);
        s.profile=std::getenv("SUPERMODEL_BENCH_FRAMES")!=nullptr;
        s.profilePasses=s.profile && std::getenv("SUPERMODEL_PROFILE_PASSES")!=nullptr;
        if (const char* warmup=std::getenv("SUPERMODEL_BENCH_WARMUP"))
            s.profileWarmup=std::min(36000ul,std::strtoul(warmup,nullptr,10));
        for (auto& frame : s.frames) {
            if (s.profilePasses) {
                auto counters=[MTL4CounterHeapDescriptor new];
                counters.type=MTL4CounterHeapTypeTimestamp;counters.count=256;
                frame.counters=[s.device newCounterHeapWithDescriptor:counters error:&error];
                if (!frame.counters) return s.Fail(@"Create GPU pass counters",error);
                frame.counterLabels.reserve(256);
            }
            frame.allocator = [s.device newCommandAllocator];
            frame.commands = [s.device newCommandBuffer];
            auto descriptor = [MTLResidencySetDescriptor new];
            descriptor.initialCapacity = 256;
            frame.residency = [s.device newResidencySetWithDescriptor:descriptor error:&error];
            frame.keepAlive = [NSMutableArray new];
            auto arguments=[MTL4ArgumentTableDescriptor new];
            arguments.maxBufferBindCount=2;
            arguments.maxTextureBindCount=2;
            arguments.initializeBindings=YES;
            frame.arguments=[s.device newArgumentTableWithDescriptor:arguments error:&error];
            if (!frame.allocator || !frame.commands || !frame.residency || !frame.arguments)
                return s.Fail(@"Create Metal 4 frame resources", error);
        }
        s.layer = (__bridge CAMetalLayer*)metalLayer;
        s.layer.device = s.device;
        // The layer owns additional presentation allocations beyond the texture
        // returned by nextDrawable. Its dynamic set tracks the entire pool.
        auto presentationResidency=s.layer.residencySet;
        if (!presentationResidency) return s.Fail("CAMetalLayer presentation residency is unavailable");
        [s.queue addResidencySet:presentationResidency];
        s.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        s.layer.framebufferOnly = NO; // Screenshot readback is part of the renderer contract.
        s.layer.maximumDrawableCount = s.frames.size();
        s.layer.allowsNextDrawableTimeout = YES;
        s.initialized = true;
        return true;
    }
}

bool Context::Resize(uint32_t width, uint32_t height, bool vsync) {
    auto& s = *m_native;
    if (!s.initialized || s.recording) return s.Fail("Resize requires an idle initialized Metal 4 context");
    if (!WaitIdle()) return false;
    s.width = width;
    s.height = height;
    s.clip = {0, 0, width, height};
    s.layer.drawableSize = CGSizeMake(width, height);
    s.layer.displaySyncEnabled = vsync;
    s.nextPresentation=0;s.presentationEpoch=s.presentationFrame+1;
    {std::lock_guard<std::mutex> guard(s.feedback->mutex);
        s.feedback->presentationPhaseEpoch=s.presentationEpoch;s.feedback->presentationPhaseOffset=-1;}
    return true;
}

void Context::SetPresentationInterval(double seconds) {
    auto& s=*m_native;
    if(s.presentationInterval!=seconds) {
        s.presentationInterval=seconds;s.nextPresentation=0;s.presentationEpoch=s.presentationFrame+1;
        std::lock_guard<std::mutex> guard(s.feedback->mutex);
        s.feedback->presentationPhaseEpoch=s.presentationEpoch;s.feedback->presentationPhaseOffset=-1;
    }
}

bool Context::BeginFrame() {
    @autoreleasepool {
        auto& s = *m_native;
        if (!s.initialized || s.recording) return s.Fail("Invalid Metal 4 BeginFrame state");
        if (!Error().empty()) return false;
        if (!s.width || !s.height) return false; // Minimized/zero-size window.
        if (s.profile) s.acquireStart=CACurrentMediaTime();
        auto& f = s.Frame();
        if (f.completion && ![s.completed waitUntilSignaledValue:f.completion timeoutMS:GPUWaitMilliseconds]) {
            s.timedOut = true;
            return s.Fail("Timed out waiting for a Metal 4 frame slot");
        }
        s.ResolvePasses(f);f.counterFrame=s.profileFrames;
        double slotEnd=s.profile?CACurrentMediaTime():0;
        // Completed slots no longer need to pin their presented drawable's
        // texture while waiting for their next turn in the three-slot ring.
        // Release on this render thread, never from an asynchronous callback.
        uint64_t completed=s.completed.signaledValue;
        for (auto& previous:s.frames) {
            if (previous.completion && previous.completion<=completed && !previous.resident.empty()) {
                [previous.keepAlive removeAllObjects];
                previous.retained.clear();previous.resident.clear();
                [previous.residency removeAllAllocations];[previous.residency commit];
            }
        }
        // No reuse/reset while the GPU can still reference this slot.
        [f.keepAlive removeAllObjects];
        f.retained.clear();f.resident.clear();
        f.constantPage=0;f.constantOffset=0;
        [f.residency removeAllAllocations];
        [f.residency commit];
        [f.allocator reset];
        double cleanupEnd=s.profile?CACurrentMediaTime():0;
        s.drawable=[s.layer nextDrawable];
        if(s.profile) {
            Stages().slotWait=1000*(slotEnd-s.acquireStart);
            Stages().cleanup=1000*(cleanupEnd-slotEnd);
            Stages().drawable=1000*(CACurrentMediaTime()-cleanupEnd);
        }
        if (!s.drawable) return false;
        [s.queue waitForDrawable:s.drawable];
        if (s.profile) s.encodeStart=CACurrentMediaTime();
        [f.commands beginCommandBufferWithAllocator:f.allocator];
        [f.commands useResidencySet:f.residency];
        s.recording = true;
        s.sceneOccluded=false;s.sceneClip=s.clip;
        s.Timestamp("start");
        s.Use(s.drawable.texture);
        // The emulated GPU can be unready during startup/reset. Such a frame
        // still presents a defined black image, rather than an unread drawable.
        auto clear=BeginSurfacePass(s,s.drawable.texture,true,
            MTLViewport{0,0,double(s.drawable.texture.width),double(s.drawable.texture.height),0,1},
            MTLScissorRect{0,0,s.drawable.texture.width,s.drawable.texture.height});
        if (!clear) return false;
        [clear endEncoding];
        if (s.colourTarget) {
            auto target=s.colourTarget;
            auto offscreen=BeginSurfacePass(s,target,true,
                MTLViewport{0,0,double(target.width),double(target.height),0,1},
                MTLScissorRect{0,0,target.width,target.height});
            if (!offscreen) return false;
            [offscreen endEncoding];
        }
        return true;
    }
}

bool Context::SubmitFrame() {
    @autoreleasepool {
        auto& s = *m_native;
        if (!s.recording) return s.Fail("SubmitFrame without Metal 4 BeginFrame");
        auto& f = s.Frame();
        s.Timestamp("other passes");
        auto image=s.drawable.texture;
        if (!s.lastFrame || s.lastFrame.width!=image.width || s.lastFrame.height!=image.height) {
            auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:image.width height:image.height mipmapped:NO];
            descriptor.storageMode=MTLStorageModePrivate;
            s.lastFrame=[s.device newTextureWithDescriptor:descriptor];
            if (!s.lastFrame) return s.Fail("Cannot allocate native screenshot image");
        }
        auto copy=[f.commands computeCommandEncoder];
        if (!copy) return s.Fail("Cannot create native screenshot copy encoder");
        Synchronize(copy);s.Use(s.lastFrame);
        [copy copyFromTexture:image toTexture:s.lastFrame];
        [copy endEncoding];
        [f.residency commit];
        [f.commands endCommandBuffer];
        auto options = [MTL4CommitOptions new];
        auto feedback = s.feedback; // Callback owns state, never a dangling Context pointer.
        bool profileGPU=s.profile && s.profileFrames>=s.profileWarmup;
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> result) {
            if (result.error) feedback->Set(result.error.localizedDescription.UTF8String);
            if (profileGPU) feedback->RecordGPU(1000*(result.GPUEndTime-result.GPUStartTime));
        }];
        id<MTL4CommandBuffer> commands[] = { f.commands };
        [s.queue commit:commands count:1 options:options];
        f.completion = ++s.serial;
        [s.queue signalEvent:s.completed value:f.completion];
        [s.queue signalDrawable:s.drawable];
        uint64_t presentationFrame=++s.presentationFrame;
        bool measurePresentation=s.profile && s.profileFrames>=s.profileWarmup && s.profileFrames-s.profileWarmup<36000;
        size_t frameNumber=s.profileFrames;
        double requestedPresentation=0;
        if (s.layer.displaySyncEnabled && s.presentationInterval>0) {
            // GPU completion time varies with scene complexity. Schedule a
            // steady configured presentation cadence instead of presenting ASAP.
            // The existing three-drawable pool provides bounded burst headroom.
            double now=CACurrentMediaTime();
            if (!s.nextPresentation || s.nextPresentation<now)
                s.nextPresentation=now+2.5*s.presentationInterval;
            // Follow the actual display phase when it supplies the requested
            // 60-Hz cadence, retaining its measured compositor delay. This
            // avoids drifting onto the following refresh. Other rates retain their
            // fractional cadence instead of snapping to the latest vblank.
            {
                std::lock_guard<std::mutex> guard(feedback->mutex);
                if (std::abs(s.presentationInterval-1.0/60.0)<1e-6 &&
                    feedback->latestPresentationFrame>=s.presentationEpoch &&
                    feedback->latestPresentationFrame<presentationFrame &&
                    feedback->presentationPhaseOffset>=0 &&
                    std::abs(feedback->latestPresentationPeriod-s.presentationInterval)<0.0005) {
                    double target=feedback->latestPresentationTime+
                        double(presentationFrame-feedback->latestPresentationFrame)*s.presentationInterval-feedback->presentationPhaseOffset;
                    if(target>now)s.nextPresentation=target;
                }
            }
            requestedPresentation=s.nextPresentation;
            s.nextPresentation+=s.presentationInterval;
        }
        [s.drawable addPresentedHandler:^(id<MTLDrawable> image) {
            feedback->RecordPresentation(presentationFrame,frameNumber,image.presentedTime,requestedPresentation,measurePresentation);
        }];
        if(requestedPresentation>0)[s.drawable presentAtTime:requestedPresentation];
        else [s.drawable present];
        s.drawable=nil;
        s.recording=false;
        s.frameIndex = (s.frameIndex + 1) % s.frames.size();
        if (s.profile && ++s.profileFrames>s.profileWarmup && s.encodeTimes.size()<36000) {
            s.encodeTimes.push_back(1000*(CACurrentMediaTime()-s.encodeStart));
            s.acquireTimes.push_back(1000*(s.encodeStart-s.acquireStart));
        }
        return Error().empty();
    }
}

bool Context::WaitIdle() {
    auto& s = *m_native;
    if (s.recording) return s.Fail("Cannot wait while a Metal 4 command buffer is recording");
    if (s.serial && ![s.completed waitUntilSignaledValue:s.serial timeoutMS:GPUWaitMilliseconds]) {
        s.timedOut = true;
        return s.Fail("Timed out waiting for Metal 4 GPU completion");
    }
    return Error().empty();
}

bool Context::ReadRGBA(std::vector<uint8_t>& pixels,uint32_t& width,uint32_t& height) {
    @autoreleasepool {
        auto& s=*m_native;
        // A screenshot request may arrive while the first drawable is still
        // unavailable. Reject that request without poisoning the render context.
        if (!s.initialized || !s.lastFrame || s.recording) return false;
        width=uint32_t(s.lastFrame.width);height=uint32_t(s.lastFrame.height);
        size_t stride=(size_t(width)*4+255)&~size_t(255);
        auto buffer=[s.device newBufferWithLength:stride*height options:MTLResourceStorageModeShared];
        auto allocator=[s.device newCommandAllocator];auto commands=[s.device newCommandBuffer];
        NSError* error=nil;
        auto residency=[s.device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
        if (!buffer || !allocator || !commands || !residency) return s.Fail(@"Create screenshot resources",error);
        [residency addAllocation:buffer];[residency addAllocation:s.lastFrame];[residency commit];
        [commands beginCommandBufferWithAllocator:allocator];[commands useResidencySet:residency];
        auto copy=[commands computeCommandEncoder];
        if (!copy) {
            [commands endCommandBuffer];
            return s.Fail("Cannot create screenshot readback encoder");
        }
        Synchronize(copy);
        [copy copyFromTexture:s.lastFrame sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(width,height,1) toBuffer:buffer destinationOffset:0
            destinationBytesPerRow:stride destinationBytesPerImage:0];
        [copy endEncoding];[commands endCommandBuffer];
        auto options=[MTL4CommitOptions new];auto feedback=s.feedback;
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> result) {
            if(result.error)feedback->Set(result.error.localizedDescription.UTF8String);
        }];
        id<MTL4CommandBuffer> list[]={commands};[s.queue commit:list count:1 options:options];
        [s.queue signalEvent:s.completed value:++s.serial];
        // Keep objects alive even on a terminal GPU wait failure.
        s.Retain(buffer);s.Retain(allocator);s.Retain(commands);s.Retain(residency);s.Retain(s.lastFrame);
        if (!WaitIdle()) return false;
        pixels.resize(size_t(width)*height*4);
        const auto* src=static_cast<const uint8_t*>(buffer.contents);
        for (uint32_t y=0;y<height;++y) for (uint32_t x=0;x<width;++x) {
            size_t a=size_t(y)*stride+x*4,b=(size_t(y)*width+x)*4;
            pixels[b]=src[a+2];pixels[b+1]=src[a+1];pixels[b+2]=src[a];pixels[b+3]=src[a+3];
        }
        return true;
    }
}

bool Context::Flush() {
    @autoreleasepool {
        auto& s = *m_native;
        if (!s.recording) return s.Fail("Flush without Metal 4 BeginFrame");
        auto& f = s.Frame();
        [f.residency commit];
        [f.commands endCommandBuffer];
        id<MTL4CommandBuffer> commands[] = {f.commands};
        auto options = [MTL4CommitOptions new];
        auto feedback = s.feedback;
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> result) {
            if (result.error) feedback->Set(result.error.localizedDescription.UTF8String);
        }];
        [s.queue commit:commands count:1 options:options];
        f.completion = ++s.serial;
        [s.queue signalEvent:s.completed value:f.completion];
        s.recording = false;
        if (!WaitIdle()) return false;
        // Retain the preceding command object and all resources until the frame
        // slot completes. Never reset the allocator during an in-progress frame.
        s.Retain(f.commands);
        f.commands = [s.device newCommandBuffer];
        if (!f.commands) return s.Fail("Cannot continue Metal 4 frame after readback");
        [f.commands beginCommandBufferWithAllocator:f.allocator];
        [f.commands useResidencySet:f.residency];
        s.recording = true;
        return true;
    }
}

void Context::Shutdown() {
    auto& s = *m_native;
    if (s.recording) {
        // The owner must end every render/compute encoder before destroying the context.
        [s.Frame().commands endCommandBuffer];
        s.recording = false;
    }
    WaitIdle();
    for (auto& frame:s.frames) s.ResolvePasses(frame);
    if (s.profile) {
        std::vector<double> gpuTimes,presentTimes;
        size_t notPresented=0;
        {
            std::unique_lock<std::mutex> guard(s.feedback->mutex);
            if(s.profileFrames>s.profileWarmup)
                s.feedback->presented.wait_for(guard,std::chrono::seconds(1),[&]{return s.feedback->lastPresented>=s.profileFrames-1;});
            gpuTimes=s.feedback->gpuTimes;
            auto times=s.feedback->presentationTimes;
            std::sort(times.begin(),times.end());
            for(size_t i=0;i<times.size();++i) {
                if(times[i].second<=0) {++notPresented;continue;}
                if(i && times[i-1].second>0)presentTimes.push_back(1000*(times[i].second-times[i-1].second));
            }
            std::fprintf(stderr,"Metal4 presentation: callbacks=%zu expected=%zu not_presented=%zu over_20ms=%zu over_25ms=%zu\n",times.size(),s.profileFrames>s.profileWarmup?s.profileFrames-s.profileWarmup:0,notPresented,
                size_t(std::count_if(presentTimes.begin(),presentTimes.end(),[](double x){return x>20;})),
                size_t(std::count_if(presentTimes.begin(),presentTimes.end(),[](double x){return x>25;})));
        }
        for (auto item:{std::make_pair("encode_ms",&s.encodeTimes),std::make_pair("acquire_ms",&s.acquireTimes),
            std::make_pair("gpu_ms",&gpuTimes),std::make_pair("present_ms",&presentTimes)}) {
            auto& values=*item.second;
            if (values.empty()) continue;
            std::sort(values.begin(),values.end());
            std::fprintf(stderr,"Metal4 %s: n=%zu mean=%.6f p95=%.6f p99=%.6f max=%.6f\n",item.first,values.size(),
                std::accumulate(values.begin(),values.end(),0.0)/values.size(),
                values[size_t((values.size()-1)*.95)],values[size_t((values.size()-1)*.99)],values.back());
        }
    }
    if (s.timedOut) {
        // Terminal device failure: keep submitted resource lifetimes until process exit.
        // Releasing in-flight allocators/textures is unsafe after a failed completion wait.
        static auto* failedContexts = new std::vector<std::unique_ptr<NativeState>>;
        static auto* failedMutex = new std::mutex;
        std::lock_guard<std::mutex> guard(*failedMutex);
        failedContexts->push_back(std::move(m_native));
        m_native = std::make_unique<NativeState>();
        return;
    }
    m_native = std::make_unique<NativeState>();
}

id<MTLRenderPipelineState> MakePipeline(NativeState& s, const char* vertex,
    const char* fragment, bool sceneTargets, unsigned layer, bool blend,
    MTLPixelFormat outputFormat,bool alphaOne,int textureFormat) {
    auto descriptor = [MTL4RenderPipelineDescriptor new];
    auto v = [MTL4LibraryFunctionDescriptor new];
    v.library = s.library;
    v.name = [NSString stringWithUTF8String:vertex];
    auto f = [MTL4LibraryFunctionDescriptor new];
    f.library = s.library;
    f.name = [NSString stringWithUTF8String:fragment];
    bool conservative=sceneTargets && textureFormat!=-2 && std::strcmp(vertex,"real3d_quad_vertex")==0;
    if (sceneTargets) {
        auto specialized=[MTL4SpecializedFunctionDescriptor new];
        specialized.functionDescriptor=v;
        auto constants=[MTLFunctionConstantValues new];
        [constants setConstantValue:&conservative type:MTLDataTypeBool atIndex:2];
        specialized.constantValues=constants;
        descriptor.vertexFunctionDescriptor=specialized;
    } else descriptor.vertexFunctionDescriptor = v;
    if (conservative) f.name=@"real3d_quad_fragment_culled";
    if (sceneTargets) {
        auto specialized=[MTL4SpecializedFunctionDescriptor new];
        specialized.functionDescriptor=f;
        auto constants=[MTLFunctionConstantValues new];
        [constants setConstantValue:&textureFormat type:MTLDataTypeInt atIndex:0];
        specialized.constantValues=constants;
        descriptor.fragmentFunctionDescriptor=specialized;
    } else descriptor.fragmentFunctionDescriptor = f;
    for (unsigned i=0; i<(sceneTargets?3u:1u); ++i) {
        auto a = descriptor.colorAttachments[i];
        a.pixelFormat = sceneTargets ? ((layer==0 || layer==i)?MTLPixelFormatRGBA8Unorm:MTLPixelFormatInvalid) : outputFormat;
        a.writeMask = (!sceneTargets || layer==0 || layer==i) ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
        a.blendingState = blend ? MTL4BlendStateEnabled : MTL4BlendStateDisabled;
        a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        a.sourceAlphaBlendFactor = alphaOne?MTLBlendFactorOne:MTLBlendFactorSourceAlpha;
        a.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    NSError* error = nil;
    auto pipeline = [s.compiler newRenderPipelineStateWithDescriptor:descriptor compilerTaskOptions:nil error:&error];
    if (!pipeline) s.Fail(@"Compile Metal 4 render pipeline",error);
    return pipeline;
}

id<MTL4ArgumentTable> MakeArguments(NativeState& s, id<MTLBuffer> vertices,
    const void* uniforms, size_t uniformSize, unsigned uniformIndex,
    id<MTLTexture> texture0, id<MTLTexture> texture1) {
    auto& frame=s.Frame();
    auto arguments=frame.arguments;
    MTLGPUAddress buffers[2]={};
    if (vertices) { buffers[0]=vertices.gpuAddress; s.Use(vertices); }
    if (uniforms && uniformSize) {
        // Each draw owns a distinct aligned range until this frame slot completes.
        // Pages are reused only after BeginFrame's completion-event wait.
        constexpr size_t pageBytes=1024*1024;
        size_t bytes=(uniformSize+255)&~size_t(255);
        if (frame.constantPage<frame.constantPages.size() &&
            frame.constantOffset+bytes>frame.constantPages[frame.constantPage].length) {
            ++frame.constantPage;frame.constantOffset=0;
        }
        if (frame.constantPage==frame.constantPages.size()) {
            auto buffer=[s.device newBufferWithLength:std::max(pageBytes,bytes) options:MTLResourceStorageModeShared];
            if (!buffer) {s.Fail("Cannot allocate Metal 4 constant page");return nil;}
            frame.constantPages.push_back(buffer);
        }
        auto constants=frame.constantPages[frame.constantPage];
        if (frame.constantOffset+bytes>constants.length) {
            s.Fail("Metal 4 constant page range overflow");return nil;
        }
        std::memcpy(static_cast<uint8_t*>(constants.contents)+frame.constantOffset,uniforms,uniformSize);
        buffers[uniformIndex]=constants.gpuAddress+frame.constantOffset;
        frame.constantOffset+=bytes;
        s.Use(constants);
    }
    MTLResourceID textures[2]={texture0?texture0.gpuResourceID:MTLResourceID{0},
        texture1?texture1.gpuResourceID:MTLResourceID{0}};
    for (unsigned i=0;i<2;++i) {
        if (buffers[i]!=frame.boundBuffers[i]) {
            [arguments setAddress:buffers[i] atIndex:i];frame.boundBuffers[i]=buffers[i];
        }
        if (textures[i]._impl!=frame.boundTextures[i]._impl) {
            [arguments setTexture:textures[i] atIndex:i];frame.boundTextures[i]=textures[i];
        }
    }
    s.Use(texture0);s.Use(texture1);
    // Metal 4 snapshots argument-table bindings at draw/dispatch encoding time
    // (MTL4RenderCommandEncoder.h). Callers must draw before changing this table.
    return arguments;
}

id<MTL4RenderCommandEncoder> BeginSurfacePass(NativeState& s, id<MTLTexture> target,
    bool clear, MTLViewport viewport, MTLScissorRect clip,MTLClearColor clearColour) {
    if (!s.recording || !target) {s.Fail("Missing native surface target/frame");return nil;}
    auto pass=[MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture=target;
    pass.colorAttachments[0].loadAction=clear?MTLLoadActionClear:MTLLoadActionLoad;
    pass.colorAttachments[0].clearColor=clearColour;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    s.Use(target);
    auto e=[s.Frame().commands renderCommandEncoderWithDescriptor:pass];
    if (!e) {s.Fail("Cannot create native surface encoder");return nil;}
    Synchronize(e);
    [e setViewport:viewport];[e setScissorRect:clip];[e setCullMode:MTLCullModeNone];
    return e;
}
}
