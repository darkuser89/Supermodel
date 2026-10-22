// Private native implementation details; never include from portable C++.
#pragma once
#if !defined(__OBJC__) || !defined(__arm64__)
#error "The Metal 4 backend requires Objective-C++ and Apple Silicon arm64"
#endif
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "Context.h"
#include "ShaderTypes.h"
#include <array>
#include <algorithm>
#include <cstdio>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cmath>
#include <vector>
#include <unordered_set>

namespace SupermodelMetal4 {
struct FeedbackState {
    std::mutex mutex;
    std::string error;
    std::vector<double> gpuTimes;
    std::condition_variable presented;
    std::vector<std::pair<size_t,double>> presentationTimes;
    size_t lastPresented=0;
    uint64_t latestPresentationFrame=0;
    double latestPresentationTime=0,latestPresentationPeriod=0,presentationPhaseOffset=-1;
    uint64_t presentationPhaseEpoch=0;
    void RecordPresentation(uint64_t sequence,size_t frame,double time,double requested,bool measure) {
        std::lock_guard<std::mutex> guard(mutex);
        if(time>0 && sequence>latestPresentationFrame) {
            latestPresentationPeriod=sequence==latestPresentationFrame+1 && latestPresentationTime>0
                ?time-latestPresentationTime:0;
            latestPresentationFrame=sequence;latestPresentationTime=time;
            if(sequence>=presentationPhaseEpoch && presentationPhaseOffset<0 && requested>0 &&
                std::abs(latestPresentationPeriod-1.0/60.0)<0.0005) {
                // Keep the measured compositor delay and center its refresh
                // window; presentedTime is not the presentAtTime deadline.
                constexpr double halfPeriod=1.0/120.0;
                presentationPhaseOffset=(std::floor((time-requested)/halfPeriod)+0.5)*halfPeriod;
            }
        }
        if(measure) {
            if(presentationTimes.size()<36000)presentationTimes.emplace_back(frame,time);
            lastPresented=std::max(lastPresented,frame);presented.notify_all();
        }
    }
    void RecordGPU(double milliseconds) {
        std::lock_guard<std::mutex> guard(mutex);
        if (milliseconds>0 && gpuTimes.size()<36000) gpuTimes.push_back(milliseconds);
    }
    void Set(const std::string& text) {
        std::lock_guard<std::mutex> guard(mutex);
        if (error.empty()) error = text;
    }
    std::string Get() {
        std::lock_guard<std::mutex> guard(mutex);
        return error;
    }
};

struct FrameSlot {
    id<MTL4CommandAllocator> allocator;
    id<MTL4CommandBuffer> commands;
    id<MTLResidencySet> residency;
    NSMutableArray* keepAlive;
    std::unordered_set<const void*> retained, resident;
    id<MTL4ArgumentTable> arguments;
    MTLGPUAddress boundBuffers[2]={};
    MTLResourceID boundTextures[2]={};
    std::vector<id<MTLBuffer>> constantPages;
    size_t constantPage=0,constantOffset=0;
    uint64_t completion = 0;
    id<MTL4CounterHeap> counters;
    std::vector<const char*> counterLabels;
    uint64_t counterFrame=0;
};

struct NativeState {
    id<MTLDevice> device;
    id<MTL4CommandQueue> queue;
    id<MTL4Compiler> compiler;
    id<MTLLibrary> library;
    id<MTLSharedEvent> completed;
    CAMetalLayer* layer;
    id<CAMetalDrawable> drawable;
    id<MTLTexture> colourTarget; // Frame mixer output; nil selects the drawable.
    id<MTLTexture> lastFrame; // Owned copy; presented drawables must never be read again.
    std::array<FrameSlot, 3> frames;
    std::shared_ptr<FeedbackState> feedback = std::make_shared<FeedbackState>();
    unsigned frameIndex = 0;
    uint64_t serial = 0;
    uint32_t width = 0, height = 0;
    // Native top-origin clip rectangle, configured by the video/mixer layer.
    MTLScissorRect clip = {0, 0, 0, 0};
    bool recording = false;
    bool sceneOccluded = false;
    MTLScissorRect sceneClip = {};
    bool initialized = false;
    // A failed GPU wait must not release resources which may still be in use.
    bool timedOut = false;
    // Bounded diagnostics enabled only by the explicit benchmark environment.
    bool profile=false;
    bool profilePasses=false;
    size_t profileFrames=0,profileWarmup=120;
    double acquireStart=0,encodeStart=0;
    double nextPresentation=0,presentationInterval=0;
    uint64_t presentationFrame=0,presentationEpoch=0;
    std::vector<double> encodeTimes,acquireTimes;

    void Timestamp(const char* label) {
        auto& f=Frame();
        if (!profilePasses || f.counterLabels.size()>=256) return;
        [f.commands writeTimestampIntoHeap:f.counters atIndex:f.counterLabels.size()];
        f.counterLabels.push_back(label);
    }
    void ResolvePasses(FrameSlot& f) {
        if (!profilePasses || f.counterLabels.empty()) return;
        NSData* data=[f.counters resolveCounterRange:NSMakeRange(0,f.counterLabels.size())];
        const auto* entries=static_cast<const MTL4TimestampHeapEntry*>(data.bytes);
        double scale=1000.0/[device queryTimestampFrequency];
        if (entries && data.length==f.counterLabels.size()*sizeof(*entries))
            for (size_t i=1;i<f.counterLabels.size();++i) {
                double ms=(entries[i].timestamp-entries[i-1].timestamp)*scale;
                if (ms>2) std::fprintf(stderr,"Metal4 pass frame=%llu index=%zu %s ms=%.6f\n",(unsigned long long)f.counterFrame,i,f.counterLabels[i],ms);
            }
        f.counterLabels.clear();
    }
    FrameSlot& Frame() { return frames[frameIndex]; }
    bool Fail(const std::string& text) { feedback->Set(text); return false; }
    bool Fail(NSString* action, NSError* error) {
        return Fail(std::string(action.UTF8String) + ": " +
            (error ? error.localizedDescription.UTF8String : "Metal returned nil"));
    }
    void Retain(id object) {
        if (object && Frame().retained.insert((__bridge const void*)object).second)
            [Frame().keepAlive addObject:object];
    }
    void Use(id<MTLAllocation> allocation) {
        if (allocation && Frame().resident.insert((__bridge const void*)allocation).second) {
            [Frame().residency addAllocation:allocation];
            Retain(allocation);
        }
    }
};

// Every native pass explicitly orders resource accesses against earlier passes.
// Metal 4 does not inherit OpenGL's implicit resource synchronization.
inline void Synchronize(id<MTL4CommandEncoder> encoder) {
    [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
}

id<MTLRenderPipelineState> MakePipeline(NativeState& s, const char* vertex,
    const char* fragment, bool sceneTargets, unsigned layer, bool blend,
    MTLPixelFormat outputFormat, bool alphaOne = false, int textureFormat = -2);
id<MTL4ArgumentTable> MakeArguments(NativeState& s, id<MTLBuffer> vertices,
    const void* uniforms, size_t uniformSize, unsigned uniformIndex,
    id<MTLTexture> texture0 = nil, id<MTLTexture> texture1 = nil);
id<MTL4RenderCommandEncoder> BeginSurfacePass(NativeState& s, id<MTLTexture> target,
    bool clear, MTLViewport viewport, MTLScissorRect clip,
    MTLClearColor clearColour = MTLClearColorMake(0,0,0,0));
}
