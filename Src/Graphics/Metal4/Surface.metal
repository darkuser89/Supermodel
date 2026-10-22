// Supermodel native Metal shaders, derived from New3D/Render2D/SuperAA.
// Copyright 2003-2026 The Supermodel Team. GPL-3.0-or-later.
#include "ShaderTypes.h"

struct SurfaceVarying {
    float4 position [[position]];
    float2 uv;
};
struct LayerColours {
    float4 colour [[color(0)]];
    float4 trans1 [[color(1)]];
    float4 trans2 [[color(2)]];
};

vertex SurfaceVarying surface_vertex(uint id [[vertex_id]]) {
    constexpr float2 positions[4] = {float2(-1,-1),float2(-1,1),float2(1,-1),float2(1,1)};
    constexpr float2 uv[4] = {float2(0,1),float2(0,0),float2(1,1),float2(1,0)};
    return {float4(positions[id],0,1),uv[id]};
}

float4 cubic(float v) {
    float4 n = float4(1,2,3,4)-v;
    float4 s = n*n*n;
    float x=s.x, y=s.y-4*s.x, z=s.z-4*s.y+6*s.x;
    return float4(x,y,z,6-x-y-z) / 6.0f;
}

float4 bicubic(texture2d<float> tex, float2 uv) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 size=float2(tex.get_width(),tex.get_height());
    float2 invSize=1.0f/size;
    uv=uv*size-0.5f;
    float2 uvi=floor(uv), fxy=uv-uvi;
    float4 x=cubic(fxy.x), y=cubic(fxy.y);
    float4 c=uvi.xxyy + float2(-0.5f,1.5f).xyxy;
    float4 s=float4(x.xz+x.yw,y.xz+y.yw);
    float4 offset=(c+float4(x.yw,y.yw)/s)*invSize.xxyy;
    float4 a=tex.sample(linearSampler,offset.xz);
    float4 b=tex.sample(linearSampler,offset.yz);
    float4 d=tex.sample(linearSampler,offset.xw);
    float4 e=tex.sample(linearSampler,offset.yw);
    return mix(mix(e,d,s.x/(s.x+s.y)),mix(b,a,s.x/(s.x+s.y)),s.z/(s.z+s.w));
}

fragment float4 tile_fragment(SurfaceVarying in [[stage_in]],
    texture2d<float> tex [[texture(0)]], constant SurfaceUniforms& u [[buffer(0)]]) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    if (u.upscaleMode==3) return bicubic(tex,in.uv);
    if (u.upscaleMode==1) {
        float2 size=float2(tex.get_width(),tex.get_height());
        float2 uv=in.uv*size+0.5f;
        float2 i=floor(uv), f=uv-i;
        f=f*f*f*(f*(f*6.0f-15.0f)+10.0f)-0.5f;
        return float4(tex.sample(linearSampler,(i+f)/size).rgb,tex.sample(linearSampler,in.uv).a);
    }
    if (u.upscaleMode==0) return tex.sample(nearestSampler,in.uv);
    return tex.sample(linearSampler,in.uv);
}

fragment float4 copy_fragment(SurfaceVarying in [[stage_in]], texture2d<float,access::read> tex [[texture(0)]]) {
    return tex.read(uint2(in.position.xy));
}

fragment float4 transparency_fragment(SurfaceVarying in [[stage_in]],
    texture2d<float,access::read> tex1 [[texture(0)]], texture2d<float,access::read> tex2 [[texture(1)]]) {
    uint2 p=uint2(in.position.xy);
    float4 a=tex1.read(p), b=tex2.read(p);
    if (a.a*b.a > 0) return float4(mix(a.rgb,b.rgb,(b.a+(1-a.a))*0.5f),1);
    return a.a>0 ? a : b;
}

fragment LayerColours scroll_fog_fragment(SurfaceVarying in [[stage_in]],
    constant SurfaceUniforms& u [[buffer(0)]]) {
    // Viewport spotlight coordinates use the original bottom-origin convention.
    float2 p=float2(in.position.x,u.targetSize.y-in.position.y);
    float ellipse=length((p-u.spotEllipse.xy)/u.spotEllipse.zw);
    ellipse=max(0.0f,1.0f-ellipse*ellipse);
    float3 spot=mix(float3(0),u.spotFogColor.rgb*ellipse*u.colour.rgb,u.fogAttenuation);
    return {float4(u.colour.rgb*u.fogAmbient+spot,u.colour.a),float4(0),float4(0)};
}

fragment float4 solid_fragment(constant SurfaceUniforms& u [[buffer(0)]]) { return u.colour; }

float srgb(float c) { return c<=0.0031308f ? 12.92f*c : 1.055f*pow(c,1.0f/2.4f)-0.055f; }
float inverseSrgb(float c) { return c<=0.04045f ? c/12.92f : pow(c/1.055f+0.055f/1.055f,2.4f); }

fragment float4 resolve_fragment(SurfaceVarying in [[stage_in]],
    texture2d<float,access::read> tex [[texture(0)]], constant SurfaceUniforms& u [[buffer(0)]]) {
    uint aa=u.supersampling;
    uint2 p=uint2(in.position.xy)*aa;
    float3 colour=0;
    for (uint i=0;i<aa;++i) for (uint j=0;j<aa;++j) colour+=tex.read(p+uint2(i,j)).rgb;
    colour/=float(aa*aa);
    if (u.crtMode!=0) {
        float3x3 m;
        if (u.crtMode==1) {
            colour=pow(colour,float3(2.5f));
            m=float3x3(float3(1.3272128334714093,-0.3802108879412366,-0.1003607696463202),
                float3(-0.0241848600268417,0.9544506228550125,0.0807358585208939),
                float3(-0.0239585810555497,-0.0409736005706461,1.4076563728858242));
        } else if (u.crtMode==2) {
            colour=pow(colour,float3(2.25f));
            m=float3x3(float3(0.9241392201737613,-0.0690701363506526,-0.0084279079392561),
                float3(0.0231962420140721,0.9729221778325590,0.0148832015024337),
                float3(-0.0054875731998806,0.0098220960740544,1.3383896683854550));
        } else {
            colour=float3(inverseSrgb(colour.r),inverseSrgb(colour.g),inverseSrgb(colour.b));
            if (u.crtMode==3)
                m=float3x3(float3(0.7822490684754086,0.0506168576073398,0.0137752498011040),
                    float3(0.0147968947158740,0.9741745313046067,0.0220301953285839),
                    float3(-0.0013501205469208,-0.0044076726925543,1.3484819844991036));
            else if (u.crtMode==4)
                m=float3x3(float3(0.9395420637732393,0.0501813568598678,0.0102765793668928),
                    float3(0.0177722231435608,0.9657928624969044,0.0164349143595347),
                    float3(-0.0016215999431855,-0.0043697496597356,1.0059913496029214));
            else
                m=float3x3(float3(1.0440432087628346,-0.0440432087628348,0.0000000000000001),
                    float3(0,1.0000000000000002,0),float3(0,0.0117933782840052,0.9882066217159947));
        }
        // GLSL uses finalColor *= colmatrix: row-vector multiplication.
        colour=colour*m;
        colour=float3(srgb(colour.r),srgb(colour.g),srgb(colour.b));
    }
    return float4(colour,1);
}

struct OverlayVertex { packed_float4 position; packed_float2 uv; packed_float4 colour; };
struct GuiVertex { packed_float2 position; packed_float2 uv; uchar4 colour; };
struct OverlayVarying { float4 position [[position]]; float2 uv; float4 colour; };

vertex OverlayVarying overlay_vertex(uint id [[vertex_id]], const device OverlayVertex* vertices [[buffer(0)]],
    constant OverlayUniforms& u [[buffer(1)]]) {
    auto a=vertices[id];
    float4 p=u.projection*float4(a.position);
    p.z=(p.z+p.w)*0.5f;
    return {p,float2(a.uv),float4(a.colour)*u.colour};
}

vertex OverlayVarying gui_vertex(uint id [[vertex_id]], const device GuiVertex* vertices [[buffer(0)]],
    constant OverlayUniforms& u [[buffer(1)]]) {
    auto a=vertices[id];
    float4 p=u.projection*float4(float2(a.position),0,1);
    p.z=(p.z+p.w)*0.5f;
    return {p,float2(a.uv),float4(a.colour)/255.0f*u.colour};
}

fragment float4 overlay_fragment(OverlayVarying in [[stage_in]], texture2d<float> tex [[texture(0)]],
    constant OverlayUniforms& u [[buffer(1)]]) {
    constexpr sampler linearSampler(filter::linear,address::clamp_to_edge);
    return u.textured ? in.colour*tex.sample(linearSampler,in.uv) : in.colour;
}

fragment float4 overlay_solid_fragment(OverlayVarying in [[stage_in]]) {
    return in.colour;
}

fragment float4 crosshair_fragment(OverlayVarying in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    // The original bitmap textures retain OpenGL's default Repeat wrap mode.
    constexpr sampler linearSampler(filter::linear,address::repeat);
    return in.colour*tex.sample(linearSampler,in.uv);
}
