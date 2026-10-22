// Optional bounded frame-time measurement. No effect unless explicitly enabled.
#pragma once
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <numeric>
#include <vector>
#include <time.h>
#include <zlib.h>
#include "Context.h"

namespace SupermodelMetal4 {
// Main-thread stages: measured only in explicitly requested benchmark runs.
struct FrameStages {
    bool enabled=std::getenv("SUPERMODEL_BENCH_FRAMES")!=nullptr;
    double render=0,sync=0,wait=0,input=0,emulation=0,mainCPU=0,ppc=0,ppcCPU=0,slotWait=0,cleanup=0,drawable=0;
};
inline FrameStages& Stages() { static FrameStages stages;return stages; }
inline uint64_t WallTime() { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }
inline uint64_t CPUTime() { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
class StageTimer {
public:
    explicit StageTimer(double& output):target(output),begin(Stages().enabled?WallTime():0) {}
    ~StageTimer() { if(begin)target=double(WallTime()-begin)/1e6; }
private:
    double& target;
    uint64_t begin;
};
class FrameBenchmark {
public:
    FrameBenchmark() {
        const char* frames=std::getenv("SUPERMODEL_BENCH_FRAMES");
        const char* output=std::getenv("SUPERMODEL_BENCH_OUTPUT");
        if (!frames || !output || !*output) return;
        char* end=nullptr;
        auto count=std::strtoul(frames,&end,10);
        if (!end || *end || !count || count>36000) return;
        file=std::fopen(output,"w");
        if (!file) return;
        limit=count;
        if (const char* value=std::getenv("SUPERMODEL_BENCH_WARMUP"))
            warmup=std::min(36000ul,std::strtoul(value,nullptr,10));
        work.reserve(limit);interval.reserve(limit);details.reserve(limit);
        if (const char* path=std::getenv("SUPERMODEL_BENCH_IMAGE_CRC")) {
            imageFile=std::fopen(path,"w");imageCRCs.reserve(limit+warmup);
        }
    }
    bool Completed() const { return limit && interval.size()==limit; }
    ~FrameBenchmark() {
        if(file)std::fclose(file);
        if(imageFile) {
            for(auto crc:imageCRCs)std::fprintf(imageFile,"%08x\n",crc);
            std::fclose(imageFile);
        }
    }
    void CaptureImage(bool paused) {
        if (!imageFile || paused || imageCRCs.size()>=72000) return;
        uint32_t width=0,height=0;
        if (GetContext().ReadRGBA(imagePixels,width,height))
            imageCRCs.push_back(uint32_t(crc32(0,imagePixels.data(),uInt(imagePixels.size()))));
    }
    bool Record(uint64_t begin,uint64_t workEnd,uint64_t end,uint64_t frequency,bool paused) {
        if (!file) return false;
        uint64_t previous=previousEnd?previousEnd:begin;
        previousEnd=end;
        if (paused) return false;
        if (warmup) {--warmup;return false;}
        details.push_back(Stages());
        work.push_back(1000.0*double(workEnd-begin)/double(frequency));
        // End-to-end intervals include the preceding loop's bookkeeping too.
        interval.push_back(1000.0*double(end-previous)/double(frequency));
        if (interval.size()<limit) return false;
        std::fprintf(file,"{\n\"frames\":%zu,\n\"metal_debug_layer\":\"%s\",\n",limit,
            std::getenv("MTL_DEBUG_LAYER") && std::atoi(std::getenv("MTL_DEBUG_LAYER")) ? "enabled" : "disabled");
        std::fprintf(file,"\"metal_shader_validation\":\"%s\",\n\"synchronous_image_check\":%s,\n",
            std::getenv("MTL_SHADER_VALIDATION") && std::atoi(std::getenv("MTL_SHADER_VALIDATION")) ? "enabled" : "disabled",
            imageFile?"true":"false");
        Write("frame_work_ms",work);std::fprintf(file,",\n");
        Write("frame_interval_ms",interval);
        double mean=std::accumulate(interval.begin(),interval.end(),0.0)/interval.size();
        std::fprintf(file,",\n\"mean_fps\":%.6f,\n\"intervals_over_17_5ms\":%zu,\n\"intervals_over_20ms\":%zu,\n\"work_over_16_667ms\":%zu\n",
            1000.0/mean,Count(interval,17.5),Count(interval,20),Count(work,1000.0/60.0));
        // Defer all diagnostic I/O until measurement is complete.
        std::fprintf(file,",\n\"outliers\":[");
        bool comma=false;
        for(size_t i=0;i<interval.size();++i) {
            if(interval[i]<=17.5 && work[i]<=1000.0/60.0)continue;
            const auto& d=details[i];
            std::fprintf(file,"%s{\"frame\":%zu,\"work_ms\":%.6f,\"interval_ms\":%.6f,\"input_ms\":%.6f,\"emulation_ms\":%.6f,\"render_ms\":%.6f,\"sync_ms\":%.6f,\"wait_ms\":%.6f,\"main_cpu_ms\":%.6f,\"ppc_ms\":%.6f,\"ppc_cpu_ms\":%.6f,\"slot_wait_ms\":%.6f,\"cleanup_ms\":%.6f,\"drawable_ms\":%.6f}",
                comma?",":"",i,work[i],interval[i],d.input,d.emulation,d.render,d.sync,d.wait,d.mainCPU,d.ppc,d.ppcCPU,d.slotWait,d.cleanup,d.drawable);
            comma=true;
        }
        std::fprintf(file,"]\n}\n");
        std::fflush(file);
        return true;
    }
private:
    static size_t Count(const std::vector<double>& values,double threshold) {
        return std::count_if(values.begin(),values.end(),[&](double value){return value>threshold;});
    }
    void Write(const char* name,std::vector<double> values) {
        std::sort(values.begin(),values.end());
        auto percentile=[&](double p){return values[size_t((values.size()-1)*p)];};
        std::fprintf(file,"\"%s\":{\"mean\":%.6f,\"p50\":%.6f,\"p95\":%.6f,\"p99\":%.6f,\"max\":%.6f}",name,
            std::accumulate(values.begin(),values.end(),0.0)/values.size(),percentile(.5),percentile(.95),percentile(.99),values.back());
    }
    FILE* file=nullptr;
    FILE* imageFile=nullptr;
    std::vector<uint32_t> imageCRCs;
    std::vector<uint8_t> imagePixels;
    size_t limit=0,warmup=120;
    uint64_t previousEnd=0;
    std::vector<double> work,interval;
    std::vector<FrameStages> details;
};
}
