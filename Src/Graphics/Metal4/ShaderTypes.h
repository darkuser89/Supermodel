// Supermodel native Metal renderer. GPL-3.0-or-later.
// Shared CPU/MSL ABI: fixed-width flags and explicitly aligned vector fields.
#pragma once
#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
#else
#include <simd/simd.h>
#include <cstdint>
namespace SupermodelMetal4 {
using float2 = simd_float2;
using float4 = simd_float4;
using int2 = simd_int2;
using int4 = simd_int4;
using float4x4 = simd_float4x4;
using uint = uint32_t;
#endif

struct DrawUniforms {
    float4x4 modelMat;
    float4x4 projMat;
    float4 fogColour;
    float4 spotEllipse;
    float4 spotColor;
    float4 spotFogColor;
    float4 lighting[2];
    int4 baseTexInfo;
    int2 textureWrapMode;
    float2 spotRange;
    float2 targetSize;
    float modelScale;
    float nodeAlpha;
    float cota;
    float microTextureMinLOD;
    float specularValue;
    float shininess;
    float fogIntensity;
    float fogDensity;
    float fogStart;
    float fogAttenuation;
    float fogAmbient;
    float layerDepthBias;
    uint textureEnabled;
    uint microTexture;
    uint microTextureID;
    uint baseTexType;
    uint textureInverted;
    uint textureAlpha;
    uint alphaTest;
    uint discardAlpha;
    uint texturePage;
    uint lightEnabled;
    uint sunClamp;
    uint intensityClamp;
    uint specularEnabled;
    uint fixedShading;
    uint smoothShading;
    uint translatorMap;
    uint step15Luminous;
    uint colourLayer;
    uint vertexOffset;
    uint padding;
};

struct SurfaceUniforms {
    float4 colour;
    float4 spotEllipse;
    float4 spotFogColor;
    float2 targetSize;
    float fogAttenuation;
    float fogAmbient;
    uint upscaleMode;
    uint supersampling;
    uint crtMode;
    uint flipY;
};

struct OverlayUniforms {
    float4x4 projection;
    float4 colour;
    uint textured;
    uint padding[3];
};

#ifndef __METAL_VERSION__
static_assert(sizeof(DrawUniforms) == 400, "CPU/MSL DrawUniforms layout changed");
static_assert(sizeof(SurfaceUniforms) == 80, "CPU/MSL SurfaceUniforms layout changed");
static_assert(sizeof(OverlayUniforms) == 96, "CPU/MSL OverlayUniforms layout changed");
}
#endif
