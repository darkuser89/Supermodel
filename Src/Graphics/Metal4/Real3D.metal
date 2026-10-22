// Supermodel native Metal 4 shaders. GPL-3.0-or-later.
// Real3D semantics derived from the current New3D GLSL shaders (Supermodel Team).
// Compile without fast math: edge classification and coplanar depth depend on it.
#include "ShaderTypes.h"

// A precompiled texture-format variant eliminates unused decoder branches and
// the whole sampling path for untextured meshes, without changing arithmetic.
constant int sceneTextureFormat [[function_constant(0)]];
constant bool sceneConservativeDepth [[function_constant(2)]];

constant bool standardProjection = is_function_constant_defined(sceneTextureFormat) && sceneTextureFormat!=-2;
constant bool opaqueDiffuse = is_function_constant_defined(sceneTextureFormat) && sceneTextureFormat==12;

struct NativeVertex {
    packed_float4 position;
    packed_float3 normal;
    packed_float2 texcoord;
    float fixedShade;
    packed_float3 faceNormal;
    uchar4 colour;
    float textureNP;
};
static_assert(sizeof(NativeVertex) == 60, "New3D FVertex ABI");
static_assert(sizeof(DrawUniforms) == 400, "DrawUniforms ABI");
static_assert(sizeof(SurfaceUniforms) == 80, "SurfaceUniforms ABI");

struct SceneResult {
    float4 colour [[color(0)]];
    float4 trans1 [[color(1)]];
    float4 trans2 [[color(2)]];
    float depth [[depth(any)]];
};
struct ConservativeSceneResult {
    float4 colour [[color(0)]];
    float4 trans1 [[color(1)]];
    float4 trans2 [[color(2)]];
    float depth [[depth(less)]];
};
struct TriangleVarying {
    float4 position [[position]];
    float3 viewVertex;
    float3 viewNormal;
    float2 texcoord;
    float4 colour;
    float fixedShade;
    float discardPoly;
    float lodBase;
};
struct QuadVarying {
    float4 position [[position]];
    float clipDistances [[clip_distance]] [2];
    float4 viewX [[flat]], viewY [[flat]], viewZ [[flat]];
    float4 normalX [[flat]], normalY [[flat]], normalZ [[flat]];
    float4 texU [[flat]], texV [[flat]], fixedShade [[flat]];
    float4 oneOverW [[flat]];
    float4 colour [[flat]];
    float lodBase [[flat]];
    float2 v0 [[center_no_perspective]], v1 [[center_no_perspective]];
    float2 v2 [[center_no_perspective]], v3 [[center_no_perspective]];
    float4 area [[center_no_perspective]];
    float4 barycentricCoords;
};
// Fragment inputs exclude the vertex-only clip-distance array.
struct QuadFragmentVarying {
    float4 position [[position]];
    float4 viewX [[flat]], viewY [[flat]], viewZ [[flat]];
    float4 normalX [[flat]], normalY [[flat]], normalZ [[flat]];
    float4 texU [[flat]], texV [[flat]], fixedShade [[flat]];
    float4 oneOverW [[flat]];
    float4 colour [[flat]];
    float lodBase [[flat]];
    float2 v0 [[center_no_perspective]], v1 [[center_no_perspective]];
    float2 v2 [[center_no_perspective]], v3 [[center_no_perspective]];
    float4 area [[center_no_perspective]];
    float4 barycentricCoords;
};
struct QuadData {
    float2 v[4];
    float area[4];
    float oneOverW[4];
    float3 viewVertex[4];
    float3 viewNormal[4];
    float2 texCoord[4];
    float4 color;
    float fixedShade[4];
    float LODBase;
    float4 barycentricCoords;
};

float glslMod(float x, float y) { return x - y * floor(x/y); }
float3x3 normalMatrix(constant DrawUniforms& u) {
    return float3x3(u.modelMat[0].xyz, u.modelMat[1].xyz, u.modelMat[2].xyz);
}
// Preserve OpenGL's clip volume. Fragment shaders write the original reverse-Z
// depth, independently of this rasterization-only [-w,w] to [0,w] conversion.
float4 metalClip(float4 p) { p.z = (p.z + p.w) * 0.5f; return p; }
TriangleVarying transformVertex(NativeVertex a, constant DrawUniforms& u) {
    TriangleVarying r;
    r.viewVertex = (u.modelMat * float4(a.position)).xyz;
    r.viewNormal = (normalMatrix(u) / u.modelScale) * float3(a.normal);
    r.discardPoly = dot(r.viewVertex, normalMatrix(u) * float3(a.faceNormal));
    r.colour = float4(a.colour) / 255.0f;
    if (u.translatorMap) r.colour.rgb *= 16.0f;
    r.colour.a *= u.nodeAlpha;
    r.texcoord = float2(a.texcoord);
    r.fixedShade = a.fixedShade;
    r.lodBase = r.discardPoly * -u.cota * a.textureNP;
    // Keep the GLSL matrix multiplication order for the projected position.
    r.position = (u.projMat * u.modelMat) * float4(a.position);
    return r;
}
vertex TriangleVarying real3d_triangle_vertex(uint id [[vertex_id]],
    const device NativeVertex* vertices [[buffer(0)]], constant DrawUniforms& u [[buffer(1)]]) {
    auto r = transformVertex(vertices[u.vertexOffset + id], u);
    r.position = metalClip(r.position);
    return r;
}
float differenceOfProducts(float a, float b, float c, float d) {
    float cd = c*d;
    float err = fma(-c,d,cd);
    float dop = fma(a,b,-cd);
    return dop + err;
}
// Geometry-shader replacement using vertex pulling. Each original quad emits
// two triangles while carrying all four original corners to the fragment stage.
// The original four-corner interpolation is preserved; these are not ordinary
// independently interpolated triangles.
vertex QuadVarying real3d_quad_vertex(uint id [[vertex_id]],
    const device NativeVertex* vertices [[buffer(0)]], constant DrawUniforms& u [[buffer(1)]]) {
    uint poly = id / 6;
    uint corner = id % 6;
    TriangleVarying a[4];
    for (uint i=0; i<4; ++i) a[i] = transformVertex(vertices[u.vertexOffset + poly*4+i],u);
    bool triangle = all(a[3].position == a[2].position);
    constexpr uint order[6] = {1,0,2, 2,0,3};
    constexpr uint triangleOrder[6] = {0,1,2, 2,2,2};
    uint ii = triangle ? triangleOrder[corner] : order[corner];
    QuadVarying r;
    float2 v[4];
    for (uint i=0;i<4;++i) {
        float iw = 1.0f / a[i].position.w;
        r.oneOverW[i] = iw;
        float3 p = a[i].viewVertex * iw;
        float3 n = a[i].viewNormal * iw;
        float2 t = a[i].texcoord * iw;
        r.viewX[i]=p.x; r.viewY[i]=p.y; r.viewZ[i]=p.z;
        r.normalX[i]=n.x; r.normalY[i]=n.y; r.normalZ[i]=n.z;
        r.texU[i]=t.x; r.texV[i]=t.y;
        r.fixedShade[i]=a[i].fixedShade * iw;
        v[i] = a[i].position.xy * iw;
    }
    float crosses[16];
    for (uint i=0;i<4;++i) {
        crosses[i*4+i]=0;
        for (uint j=i+1;j<4;++j) {
            crosses[i*4+j] = differenceOfProducts(a[i].position.x,a[j].position.y,
                a[j].position.x,a[i].position.y) / (a[i].position.w*a[j].position.w);
            crosses[j*4+i] = -crosses[i*4+j];
        }
    }
    r.v0=v[0]-v[ii]; r.v1=v[1]-v[ii]; r.v2=v[2]-v[ii]; r.v3=v[3]-v[ii];
    for (uint j=0;j<4;++j) {
        uint next=(j+1)%4;
        r.area[j]=crosses[j*4+next]+crosses[next*4+ii]+crosses[ii*4+j];
    }
    constexpr float3 bary[4] = {float3(1,0,0),float3(0,1,0),float3(0,0,1),float3(0,-1,0)};
    r.barycentricCoords = triangle ? float4(float3(ii==0,ii==1,ii==2),1) : float4(bary[ii],0);
    r.colour=a[0].colour;
    r.lodBase=a[0].lodBase;
    r.position=metalClip(a[ii].position);
    r.clipDistances[0]=r.clipDistances[1]=1;
    if (is_function_constant_defined(sceneConservativeDepth) && sceneConservativeDepth) {
        // Supply a conservative upper depth bound so reverse-Z can reject
        // hidden fragments before the expensive four-corner shader executes.
        // Preserve the original clip planes independently of raster depth.
        r.clipDistances[0]=r.position.z;
        r.clipDistances[1]=r.position.w-r.position.z;
        bool positiveW=true,positiveTurns=true,negativeTurns=true;
        float maxDepth=0;
        for(uint i=0;i<4;++i) {
            positiveW=positiveW && a[i].position.w>0 && isfinite(r.oneOverW[i]);
            float4 viewProjection=u.projMat*float4(a[i].viewVertex,1.0f);
            positiveW=positiveW && viewProjection.w>0 && isfinite(viewProjection.z);
            maxDepth=max(maxDepth,a[i].position.z*r.oneOverW[i]);
            maxDepth=max(maxDepth,viewProjection.z*r.oneOverW[i]);
            maxDepth=max(maxDepth,viewProjection.z/viewProjection.w);
            float2 e0=v[(i+1)%4]-v[i],e1=v[(i+2)%4]-v[(i+1)%4];
            float turn=e0.x*e1.y-e0.y*e1.x;
            float tolerance=1e-5f*(abs(e0.x*e1.y)+abs(e0.y*e1.x))+1e-10f;
            positiveTurns=positiveTurns && turn>tolerance;
            negativeTurns=negativeTurns && turn<-tolerance;
        }
        // Convex mean-value weights keep depth within the corner range.
        // Degenerate/crossed/concave and eye-plane cases use the universal
        // bound 1. The margin also covers interpolation roundoff at edges.
        float bound=positiveW && (triangle || positiveTurns || negativeTurns)
            ? clamp(maxDepth*1.01f+1e-5f,0.0f,1.0f):1.0f;
        r.position.z=bound*r.position.w;
    }
    if (a[0].discardPoly > 0) r.position=float4(0,0,-1,1); // fully clipped
    return r;
}

struct FragmentContext {
    constant DrawUniforms& u;
    texture2d<ushort, access::read> bank0, bank1;
    float4 coord;
    float3 fsViewVertex, fsViewNormal;
    float2 fsTexCoord;
    float4 fsColor;
    float fsFixedShade, fsLODBase, fsDiscardPoly;
    QuadData fs_in;
    SceneResult result;
    float4 sampleBank(uint bank, int2 wrapMode, float2 size, int2 pos, float2 uv, int level) {
        if (bank==0) return texBiLinear(bank0,wrapMode,size,pos,uv,level);
        return texBiLinear(bank1,wrapMode,size,pos,uv,level);
    }


#define LayerColour 0x0
#define LayerTrans0 0x1
#define LayerTrans1 0x2

float4 ExtractColour(int type, uint value)
{
    if ((is_function_constant_defined(sceneTextureFormat) && sceneTextureFormat!=-2)) type=sceneTextureFormat==12?0:sceneTextureFormat;
	float4 c = float4(0.0);

	if(type==0) {			// T1RGB5
		c.r     = float((value >> 10) & 0x1Fu);
		c.g     = float((value >> 5 ) & 0x1Fu);
		c.b     = float((value      ) & 0x1Fu);
		c.rgb  *= (1.0/31.0);
		c.a     = 1.0 - float((value >> 15) & 0x1u);
	}
	else if(type==1) {		// Interleaved A4L4 (low byte)
		c.rgb   = float3(float(value&0xFu));
		c.a     = float((value >> 4) & 0xFu);
		c      *= (1.0/15.0);
	}
	else if(type==2) {
		c.a     = float(value&0xFu);
		c.rgb   = float3(float((value >> 4) & 0xFu));
		c      *= (1.0/15.0);
	}
	else if(type==3) {
		c.rgb   = float3(float((value>>8)&0xFu));
		c.a     = float((value >> 12) & 0xFu);
		c      *= (1.0/15.0);
	}
	else if(type==4) {
		c.a     = float((value>>8)&0xFu);
		c.rgb   = float3(float((value >> 12) & 0xFu));
		c      *= (1.0/15.0);
	}
	else if(type==5) {
		c = float4(float(value&0xFFu) / 255.0);
		if(c.a==1.0)	{ c.a = 0.0; }
		else			{ c.a = 1.0; }
	}
	else if(type==6) {
		c = float4(float((value>>8)&0xFFu) / 255.0);
		if(c.a==1.0)	{ c.a = 0.0; }
		else			{ c.a = 1.0; }
	}
	else if(type==7) {	// RGBA4
		c.r = float((value>>12)&0xFu);
		c.g = float((value>> 8)&0xFu);
		c.b = float((value>> 4)&0xFu);
		c.a = float((value>> 0)&0xFu);
		c *= (1.0/15.0);
	}
	else if(type==8) {	// low byte, low nibble
		c = float4(float(value&0xFu) / 15.0);
		if(c.a==1.0)	{ c.a = 0.0; }
		else			{ c.a = 1.0; }
	}
	else if(type==9) {	// low byte, high nibble
		c = float4(float((value>>4)&0xFu) / 15.0);
		if(c.a==1.0)	{ c.a = 0.0; }
		else			{ c.a = 1.0; }
	}
	else if(type==10) {	// high byte, low nibble
		c = float4(float((value>>8)&0xFu) / 15.0);
		if(c.a==1.0)	{ c.a = 0.0; }
		else			{ c.a = 1.0; }
	}
	else if(type==11) {	// high byte, high nibble
		c = float4(float((value>>12)&0xFu) / 15.0);
		if(c.a==1.0)	{ c.a = 0.0; }
		else			{ c.a = 1.0; }
	}

	return c;
}

// hardware testing would be useful because i don't know exactly what happens if you try to read outside the texture sheet
// wrap around is a good guess
int2 WrapTexCoords(int2 pos, int2 coordinate, int level)
{
	int2 newCoord;
	newCoord.x = coordinate.x & (2047 >> level);
	newCoord.y = coordinate.y & (1023 >> level);

	return newCoord;
}

int2 GetTextureSize(int level, int2 size)
{
	int mipDivisor = 1 << level;

	return standardProjection?int2(uint2(size)>>uint(level)):size/mipDivisor;
}

int2 GetTexturePosition(int level, int2 pos)
{
	int mipDivisor = 1 << level;

	int2 retPos;
	retPos.x = standardProjection?pos.x>>level:pos.x/mipDivisor;
	retPos.y = standardProjection?pos.y>>level:pos.y/mipDivisor;

	return retPos;
}

int2 GetMicroTexturePos(int id)
{
	const int xCoords[8] = {0, 0, 128, 128, 0, 0, 128, 128};
	const int yCoords[8] = {0, 128, 0, 128, 256, 384, 256, 384};

	return int2(xCoords[id],yCoords[id]);
}

float LinearTexLocations(int wrapMode, float size, float u, thread float& u0, thread float& u1)
{
	// Texture dimensions in this variant are positive normal powers of two.
    // IEEE exponent reflection is the exact reciprocal, without division.
    float texelSize=standardProjection?as_type<float>(0x7f000000u-as_type<uint>(size)):1.0f/size;
	float halfTexelSize	= standardProjection?0.5f*texelSize:0.5f/size;

	if(wrapMode==0) {							// repeat
		u	= u * size - 0.5;
		u0	= standardProjection?(floor(u)+0.5f)*texelSize:(floor(u)+0.5f)/size;			// + 0.5 offset added to push us into the centre of a pixel, without we'll get rounding errors
		u0	= fract(u0);
		u1	= u0 + texelSize;
		u1	= fract(u1);

		return fract(u);						// return weight
	}
	else if(wrapMode==1) {						// repeat + clamp
		u	= fract(u);							// must force into 0-1 to start
		u	= u * size - 0.5;
		u0	= standardProjection?(floor(u)+0.5f)*texelSize:(floor(u)+0.5f)/size;			// + 0.5 offset added to push us into the centre of a pixel, without we'll get rounding errors
		u1	= u0 + texelSize;

		if(u0 <  0.0)	u0 = 0.0;
		if(u1 >= 1.0)	u1 = 1.0 - halfTexelSize;
		
		return fract(u);						// return weight
	}
	else {										// mirror + mirror clamp - both are the same since the edge pixels are repeated anyway
		float odd = floor(glslMod(u, 2.0));			// odd values are mirrored

		if(odd > 0.0) {
			u = 1.0 - fract(u);
		}
		else {
			u = fract(u);
		}

		u	= u * size - 0.5;
		u0	= standardProjection?(floor(u)+0.5f)*texelSize:(floor(u)+0.5f)/size;			// + 0.5 offset added to push us into the centre of a pixel, without we'll get rounding errors
		u1	= u0 + texelSize;

		if(u0 <  0.0)	u0 = 0.0;
		if(u1 >= 1.0)	u1 = 1.0 - halfTexelSize;

		return fract(u);						// return weight
	}
}

float4 texBiLinear(texture2d<ushort, access::read> texSampler, int2 wrapMode, float2 texSize, int2 texPos, float2 texCoord, int level)
{
	float tx[2], ty[2];
	float a = LinearTexLocations(wrapMode.x, texSize.x, texCoord.x, tx[0], tx[1]);
	float b = LinearTexLocations(wrapMode.y, texSize.y, texCoord.y, ty[0], ty[1]);

	float4 p0q0 = ExtractColour(u.baseTexType,texSampler.read(uint2(WrapTexCoords(texPos,int2(float2(tx[0],ty[0]) * texSize + float2(texPos)),level)), uint(level)).r);
	float4 p1q0 = ExtractColour(u.baseTexType,texSampler.read(uint2(WrapTexCoords(texPos,int2(float2(tx[1],ty[0]) * texSize + float2(texPos)),level)), uint(level)).r);
	float4 p0q1 = ExtractColour(u.baseTexType,texSampler.read(uint2(WrapTexCoords(texPos,int2(float2(tx[0],ty[1]) * texSize + float2(texPos)),level)), uint(level)).r);
	float4 p1q1 = ExtractColour(u.baseTexType,texSampler.read(uint2(WrapTexCoords(texPos,int2(float2(tx[1],ty[1]) * texSize + float2(texPos)),level)), uint(level)).r);

	if((opaqueDiffuse?false:u.alphaTest)) {
		if(p0q0.a > p1q0.a)		{ p1q0.rgb = p0q0.rgb; }
		if(p0q0.a > p0q1.a)		{ p0q1.rgb = p0q0.rgb; }

		if(p1q0.a > p0q0.a)		{ p0q0.rgb = p1q0.rgb; }
		if(p1q0.a > p1q1.a)		{ p1q1.rgb = p1q0.rgb; }

		if(p0q1.a > p0q0.a)		{ p0q0.rgb = p0q1.rgb; }
		if(p0q1.a > p1q1.a)		{ p1q1.rgb = p0q1.rgb; }

		if(p1q1.a > p0q1.a)		{ p0q1.rgb = p1q1.rgb; }
		if(p1q1.a > p1q0.a)		{ p1q0.rgb = p1q1.rgb; }
	}

	// Interpolation X direction.
	float4 pInterp_q0 = mix( p0q0, p1q0, a ); // Interpolates top row X direction.
	float4 pInterp_q1 = mix( p0q1, p1q1, a ); // Interpolates bottom row X direction.

	return mix( pInterp_q0, pInterp_q1, b ); // Interpolate Y direction.
}

float4 GetTextureValue()
{
	float lod = -log2(coord.w * coord.w * fsLODBase);
	float numLevels = floor(log2(min(float(u.baseTexInfo.z), float(u.baseTexInfo.w)))) - 1.0;	// r3d only generates down to 2:2 for square textures, otherwise its the min dimension
	float fLevel = clamp(lod, 0.0, numLevels);

	int iLevel = int(fLevel);

	int2 tex1Pos = GetTexturePosition(iLevel, u.baseTexInfo.xy);
	int2 tex1Size = GetTextureSize(iLevel, u.baseTexInfo.zw);
	float4 tex1Data = sampleBank(u.texturePage, u.textureWrapMode, float2(tex1Size), tex1Pos, fsTexCoord, iLevel);

	// init second texel with blank data to avoid any potentially undefined behavior
	float4 tex2Data = float4(0.0);

	float blendFactor = 0.0;

	// if LOD < 0, no need to blend with next mipmap level; slight performance boost
	//  while at it, just generalize to all cases where only one mip level needs to be touched
	float ffL = fract(fLevel);
	if (ffL > 0.0)
	{
		int2 tex2Pos = GetTexturePosition(iLevel+1, u.baseTexInfo.xy);
		int2 tex2Size = GetTextureSize(iLevel+1, u.baseTexInfo.zw);
		tex2Data = sampleBank(u.texturePage, u.textureWrapMode, float2(tex2Size), tex2Pos, fsTexCoord, iLevel+1);

		blendFactor = ffL;
	}
	else if ((opaqueDiffuse?false:u.microTexture) && lod < 0.0)
	{
		float4 scaleIndex = float4(2.0, 4.0, 16.0, 256.0);		// unsure if minLOD=4 has 256x scale? No games appear to use it
		float2 scale = (float2(u.baseTexInfo.zw) / 128.0) * scaleIndex[int(u.microTextureMinLOD)];

		// microtextures are always 128x128 and only use LOD 0 mipmap
		int2 tex2Pos = GetMicroTexturePos(u.microTextureID);
		tex2Data = sampleBank((u.texturePage+1)&1, int2(0), float2(128), tex2Pos, fsTexCoord * scale, 0);

		blendFactor = -lod * exp2(-u.microTextureMinLOD) * 0.5;
		blendFactor = min(blendFactor, 0.5);
	}

	tex1Data = mix(tex1Data, tex2Data, blendFactor);

	if(u.textureInverted) {
		tex1Data.rgb = float3(1.0) - tex1Data.rgb;
	}

	if ((opaqueDiffuse?false:u.alphaTest)) {
		if (tex1Data.a < (32.0/255.0)) {
			discard_fragment();
		}
	}

	if((opaqueDiffuse?false:u.textureAlpha)) {
		if(u.discardAlpha) {					// opaque 1st pass
			if (tex1Data.a < 1.0) {
				discard_fragment();
			}
		}
		else {								// transparent 2nd pass
			if ((tex1Data.a * fsColor.a) >= 1.0) {
				discard_fragment();
			}
		}
	}

	if ((opaqueDiffuse?false:u.textureAlpha) == false && (opaqueDiffuse?false:u.alphaTest) == false) {
		tex1Data.a = 1.0;
	}

	return tex1Data;
}

void Step15Luminous(thread float4& colour)
{
	// luminous polys seem to behave very differently on step 1.5 hardware
	// when fixed shading is enabled the colour is modulated by the vp ambient + fixed shade value
	// when disabled it appears to be multiplied by 1.5, presumably to allow a higher range
	if(u.step15Luminous) {
		if(!(opaqueDiffuse?true:u.lightEnabled)) {
			if((opaqueDiffuse?false:u.fixedShading)) {
				colour.rgb *= 1.0 + fsFixedShade + u.lighting[1].y;
			}
			else {
				colour.rgb *= 1.5;
			}
		}
	}
}

float CalcFog()
{
	float z		= -fsViewVertex.z;
	float fog	= u.fogIntensity * clamp(u.fogStart + z * u.fogDensity, 0.0, 1.0);

	return fog;
}

float Sqr(float a)
{
	return a*a;
}

float SqrLength(float2 a)
{
	return a.x*a.x + a.y*a.y;
}

// Computes spotlight lobe + fog lobe effects
// ------------------------------------------------------------
// Inputs:
//   u.spotEllipse   - float4(center.xy, radius.xy)
//   u.spotRange     - float2(startZ, extent)
//   viewZ         - fsViewVertex.z
//
// Outputs:
//   lobeEffect    - spotlight intensity
//   lobeFogEffect - spotlight on fog intensity
// ------------------------------------------------------------
void ComputeSpotlight(float4 ellipseParams, float2 rangeParams, float viewZ,
    thread float& lobeEffect, 
	thread float& lobeFogEffect)
{
    // Ellipse falloff
    float ellipse = SqrLength((coord.xy - ellipseParams.xy) / ellipseParams.zw);
    ellipse = 1.0 - ellipse;
    ellipse = max(0.0, ellipse);

    // Spotlight enable
    float enable = step(rangeParams.x, -viewZ);

    // Spotlight range falloff
    float range = 0.0;

    if (rangeParams.y != 0.0) {
        float absExtent = abs(rangeParams.y);

        float d = rangeParams.x + absExtent + viewZ;
        d = min(d, 0.0);

        float inv_r = 1.0 / (1.0 + absExtent);

        // inverse-linear falloff
        range = 1.0 / Sqr(d * inv_r - 1.0);
        range *= enable;
    }

    // Final outputs
    lobeEffect    = range * ellipse;
    lobeFogEffect = enable * ellipse;
}

void WriteOutputs(float4 colour, int layer)
{
	float4 blank = float4(0.0);

	if(layer==LayerColour) {
		colour.a = 1.0;		// always have alpha of 1
		result.colour = colour;
		result.trans1 = blank;
		result.trans2 = blank;
	}
	else if(layer==LayerTrans0) {
		result.colour = blank;
		result.trans1 = colour;
		result.trans2 = blank;
	}
	else if(layer==LayerTrans1) {
		result.colour = blank;
		result.trans1 = blank;
		result.trans2 = colour;
	}
}

void QuadraticInterpolation()
{
	// init interpolated projected attributes
	fsViewVertex	= float3(0.0);
	fsViewNormal	= float3(0.0);
	fsTexCoord		= float2(0.0);
	fsFixedShade	= 0.0;

	float interp_oneOverW	= 0.0;
	float uSum				= 0.0;

	const float hpFMin		= 0.00006103515625;		// half precision FLT_MIN
	bool extreme_edge		= (fs_in.barycentricCoords.w > 0.5 || fs_in.barycentricCoords.x <= hpFMin || fs_in.barycentricCoords.z <= hpFMin); // w: triangle

	// As the coordinates get closer to the poly edge the interpolated areas can approach zero which can blow up the maths leading to bad interpolation.
	// In this case we fall back to 3 point triangle interpolation (really 2 because 1 coord will be zero).
	// This code will only get triggered rarer corner cases

	float weights[4];
	if(extreme_edge)
	{
		for (int i=0; i<4; i++) {
			int b = (i == 3) ? 1  // 2nd triangle
			                 : i; // 1st triangle
			float baryCoord	= abs(fs_in.barycentricCoords[b]);
			weights[i] = baryCoord / fs_in.oneOverW[i];
			if((i == 1 && !(fs_in.barycentricCoords.y>0.0)) // ignore weights[1] if 2nd triangle
			 ||(i == 3 &&  (fs_in.barycentricCoords.y>0.0)) // ignore weights[3] if 1st triangle
			 ||(baryCoord <= hpFMin))
			{
				weights[i] = 0.0;
			}
		}
	}
	else
	{
		for (int i=0; i<4; i++)
			weights[i] = length(fs_in.v[i]) * sign(fs_in.oneOverW[i]); // is w[i] negative?

		float t[4];
		for (int i=0; i<4; i++) {
			int i_next = (i+1)%4;
			if(fs_in.area[i]==0.0) t[i] = 0.0; // check for zero area to avoid div by zero
			else                   t[i] = fma(weights[i],weights[i_next], -dot(fs_in.v[i],fs_in.v[i_next])) / fs_in.area[i];
		}

		int lambdaSignCount = 0; // to discard fragments if all the weights are neither all negative nor all positive (=outside the convex/concave/crossed quad).

		for (uint i=0; i<4; i++) {
			uint i_prev = (i-1)%4;
			weights[i] = (t[i_prev] + t[i]) / weights[i];
			lambdaSignCount += (t[i_prev] < -t[i]) ? -1 : 1;
		}

		if (lambdaSignCount == 0) { // one can either check for == 0 or abs(...) != 4, both should(!) be equivalent (but practice its not due to precision issues, but these cases are extremely rare)
			discard_fragment();	// fine for helper invocations too: nothing here uses derivatives (textures are read with texelFetch)
		}

		for (int i=0; i<4; i++) {
			interp_oneOverW	= fma(fs_in.oneOverW[i], weights[i], interp_oneOverW);
			uSum           += weights[i];
		}
	}

	// shared computations
	for (int i=0; i<4; i++) {
		fsViewVertex	= fma(fs_in.viewVertex[i], float3(weights[i]), fsViewVertex);
		fsViewNormal	= fma(fs_in.viewNormal[i], float3(weights[i]), fsViewNormal);
		fsTexCoord		= fma(fs_in.texCoord[i], float2(weights[i]), fsTexCoord);
		fsFixedShade	= fma(fs_in.fixedShade[i], weights[i], fsFixedShade);
	}

	// finalize the 2 cases
	if(extreme_edge)
	{
		float w = standardProjection?-fsViewVertex.z:(u.projMat * float4(fsViewVertex,1.0)).w;

		interp_oneOverW = 1.0 / w;
		uSum = 1.0;
	}
	else
	{
		float inv = 1.0/interp_oneOverW;
		fsViewVertex *= inv;
		fsViewNormal *= inv;
		fsTexCoord   *= inv;
		fsFixedShade *= inv;
	}

	float4 projected;
	float depth;

	// dirty hack for co-planar polys that really need 100% identical values to depth test correctly
	// the reason we waste cycles and calculate depth value here is because we have run out of vertex attributes
	if(fs_in.oneOverW[0]==fs_in.oneOverW[1] && 
	   fs_in.oneOverW[1]==fs_in.oneOverW[2] && 
	   fs_in.oneOverW[2]==fs_in.oneOverW[3]) {

		fsViewVertex.z	= fs_in.viewVertex[0].z / fs_in.oneOverW[0];
		if (standardProjection) depth=u.projMat[3][2]/(-fsViewVertex.z);
        else {
            projected=u.projMat * float4(fsViewVertex,1.0);
            depth=projected.z/projected.w;
        }
	}
	else {
		projected.z		= u.projMat[2][2] * fsViewVertex.z + u.projMat[3][2];		// standard u.projMat * projected - but just using Z components
		depth			= projected.z * (interp_oneOverW/uSum);
	}

	fsColor			= fs_in.color;
	fsLODBase		= fs_in.LODBase;

	result.depth = depth * u.layerDepthBias;
}
// At full fog, opaque RGB is independent of texture and surface lighting.
// Keep alpha rejection and fog spotlight exactly as in the complete path.
bool FinishOpaqueFog(float4 fogData) {
    if (!standardProjection || u.colourLayer!=0 || u.textureAlpha || u.alphaTest || fogData.a!=1.0f)
        return false;
    if (fsColor.a<(1.0f/32.0f))discard_fragment();
    float lobe,lobeFog;
    ComputeSpotlight(u.spotEllipse,u.spotRange,fsViewVertex.z,lobe,lobeFog);
    float3 spot=u.spotFogColor.xyz*u.fogAttenuation*u.fogColour.xyz*lobeFog;
    WriteOutputs(float4(fogData.rgb+spot,1),u.colourLayer);
    return true;
}
void shadeTriangle()
{
	float4 tex1Data;
	float4 colData;
	float4 finalData;
	float4 fogData;

	if(fsDiscardPoly > 0.0) {
		discard_fragment();		//emulate back face culling here
	}

	result.depth = u.projMat[3][2] * coord.w * u.layerDepthBias;

	fogData = float4(u.fogColour.xyz.rgb * u.fogAmbient, CalcFog());
    if(FinishOpaqueFog(fogData))return;
	tex1Data = float4(1.0, 1.0, 1.0, 1.0);

	if((is_function_constant_defined(sceneTextureFormat) && sceneTextureFormat!=-2)?sceneTextureFormat>=0:u.textureEnabled) {
		tex1Data = GetTextureValue();
	}

	colData = fsColor;
	Step15Luminous(colData);			// no-op for step 2.0+
	finalData = tex1Data * colData;

	if (finalData.a < (1.0/32.0)) {		// basically chuck out any totally transparent pixels value = 1/16 the smallest transparency level h/w supports
		discard_fragment();
	}

	float lobeEffect;
	float lobeFogEffect;
	ComputeSpotlight(u.spotEllipse, u.spotRange, fsViewVertex.z, lobeEffect, lobeFogEffect);

	if ((opaqueDiffuse?true:u.lightEnabled)) {
		float3   lightIntensity;
		float3   sunVector;     // sun u.lighting vector (as reflecting away from vertex)
		float  sunFactor;     // sun light projection along vertex normal (0.0 to 1.0)

		// Sun angle
		sunVector = u.lighting[0].xyz;

		// Compute diffuse factor for sunlight
		if((opaqueDiffuse?false:u.fixedShading)) {
			sunFactor = fsFixedShade;
		}
		else {
			sunFactor = dot(sunVector, fsViewNormal);
		}

		// Clamp ceil, fix for upscaled models without "u.modelScale" defined
		sunFactor = clamp(sunFactor,-1.0,1.0);

		// Optional clamping, value is allowed to be negative
		// We suspect that translucent polygons are always clamped (e.g. lasers Daytona 2)
		if(u.sunClamp || finalData.a<0.999) {
			sunFactor = max(sunFactor,0.0);
		}

		// Total light intensity: sum of all components 
		lightIntensity = float3(sunFactor*u.lighting[1].x + u.lighting[1].y);   // diffuse + ambient

		lightIntensity += u.spotColor.xyz*lobeEffect;

		// Upper clamp is optional, step 1.5+ games will drive brightness beyond 100%
		if(u.intensityClamp) {
			lightIntensity = min(lightIntensity,1.0);
		}

		finalData.rgb *= lightIntensity;

		// for now assume fixed shading doesn't work with specular
		if ((opaqueDiffuse?false:u.specularEnabled)) {

			float specularFactor;

			if (u.smoothShading)
			{
				// Always clamp floor to zero
				float NdotL = max(0.0, sunFactor);

				const float expIndex[4]  = {8.0, 16.0, 32.0, 64.0};
				const float multIndex[4] = {1.6, 1.6, 2.4, 3.2};
				float exponent = expIndex[int(u.shininess)];

				specularFactor = pow(NdotL, exponent);
				specularFactor *= multIndex[int(u.shininess)];
			}
			else
			{
				// flat shaded polys use Phong reflection model (R dot V) without any exponent or multiplier
				// V = (0.0, 0.0, 1.0) is used by Model 3 as a fast approximation, so R dot V = R.z
				float3 R = reflect(-sunVector, fsViewNormal);
				specularFactor = max(0.0, R.z);
			}

			specularFactor *= u.specularValue;
			specularFactor *= u.lighting[1].x;

			if (colData.a < 1.0) {
				/// Specular hi-light affects translucent polygons alpha channel ///
				finalData.a = max(finalData.a, specularFactor);
			}

			finalData.rgb += specularFactor;
		}
	}

	// Final clamp: we need it for proper shading dimmed light and dark ambients
	finalData.rgb = min(finalData.rgb, float3(1.0));

	// Spotlight on fog
	float3 lSpotFogColor = u.spotFogColor.xyz * u.fogAttenuation * u.fogColour.xyz.rgb * lobeFogEffect;

	// Fog & spotlight applied
	finalData.rgb = mix(finalData.rgb, fogData.rgb + lSpotFogColor, fogData.a);

	// Write outputs to colour buffers
	WriteOutputs(finalData,u.colourLayer);
}

void shadeQuad()
{
	float4 tex1Data;
	float4 colData;
	float4 finalData;
	float4 fogData;

	QuadraticInterpolation();	// calculate our vertex attributes

	fogData = float4(u.fogColour.xyz.rgb * u.fogAmbient, CalcFog());
    if(FinishOpaqueFog(fogData))return;
	tex1Data = float4(1.0, 1.0, 1.0, 1.0);

	if((is_function_constant_defined(sceneTextureFormat) && sceneTextureFormat!=-2)?sceneTextureFormat>=0:u.textureEnabled) {
		tex1Data = GetTextureValue();
	}

	colData = fsColor;
	Step15Luminous(colData);			// no-op for step 2.0+
	finalData = tex1Data * colData;

	if (finalData.a < (1.0/32.0)) {		// basically chuck out any totally transparent pixels value = 1/16 the smallest transparency level h/w supports
		discard_fragment();
	}

	float lobeEffect;
	float lobeFogEffect;
	ComputeSpotlight(u.spotEllipse, u.spotRange, fsViewVertex.z, lobeEffect, lobeFogEffect);

	if ((opaqueDiffuse?true:u.lightEnabled)) {
		float3   lightIntensity;
		float3   sunVector;     // sun u.lighting vector (as reflecting away from vertex)
		float  sunFactor;     // sun light projection along vertex normal (0.0 to 1.0)

		// Sun angle
		sunVector = u.lighting[0].xyz;

		// Compute diffuse factor for sunlight
		if((opaqueDiffuse?false:u.fixedShading)) {
			sunFactor = fsFixedShade;
		}
		else {
			sunFactor = dot(sunVector, fsViewNormal);
		}

		// Clamp ceil, fix for upscaled models without "u.modelScale" defined
		sunFactor = clamp(sunFactor,-1.0,1.0);

		// Optional clamping, value is allowed to be negative
		// We suspect that translucent polygons are always clamped (e.g. lasers Daytona 2)
		if(u.sunClamp || finalData.a<0.999) {
			sunFactor = max(sunFactor,0.0);
		}

		// Total light intensity: sum of all components 
		lightIntensity = float3(sunFactor*u.lighting[1].x + u.lighting[1].y);   // diffuse + ambient

		lightIntensity += u.spotColor.xyz*lobeEffect;

		// Upper clamp is optional, step 1.5+ games will drive brightness beyond 100%
		if(u.intensityClamp) {
			lightIntensity = min(lightIntensity,1.0);
		}

		finalData.rgb *= lightIntensity;

		// for now assume fixed shading doesn't work with specular
		if ((opaqueDiffuse?false:u.specularEnabled)) {

			float specularFactor;

			if (u.smoothShading)
			{
				// Always clamp floor to zero
				float NdotL = max(0.0, sunFactor);

				const float expIndex[4]  = {8.0, 16.0, 32.0, 64.0};
				const float multIndex[4] = {1.6, 1.6, 2.4, 3.2};
				float exponent = expIndex[int(u.shininess)];

				specularFactor = pow(NdotL, exponent);
				specularFactor *= multIndex[int(u.shininess)];
			}
			else
			{
				// flat shaded polys use Phong reflection model (R dot V) without any exponent or multiplier
				// V = (0.0, 0.0, 1.0) is used by Model 3 as a fast approximation, so R dot V = R.z
				float3 R = reflect(-sunVector, fsViewNormal);
				specularFactor = max(0.0, R.z);
			}

			specularFactor *= u.specularValue;
			specularFactor *= u.lighting[1].x;

			if (colData.a < 1.0) {
				/// Specular hi-light affects translucent polygons alpha channel ///
				finalData.a = max(finalData.a, specularFactor);
			}

			finalData.rgb += specularFactor;
		}
	}

	// Final clamp: we need it for proper shading dimmed light and dark ambients
	finalData.rgb = min(finalData.rgb, float3(1.0));

	// Spotlight on fog
	float3 lSpotFogColor = u.spotFogColor.xyz * u.fogAttenuation * u.fogColour.xyz.rgb * lobeFogEffect;

	// Fog & spotlight applied
	finalData.rgb = mix(finalData.rgb, fogData.rgb + lSpotFogColor, fogData.a);

	// Write outputs to colour buffers
	WriteOutputs(finalData,u.colourLayer);
}
    FragmentContext(constant DrawUniforms& uniforms, texture2d<ushort, access::read> b0,
        texture2d<ushort, access::read> b1, float4 position) : u(uniforms),bank0(b0),bank1(b1),coord(position) {
        coord.y = u.targetSize.y - coord.y;
        result = {};
    }
};
fragment SceneResult real3d_triangle_fragment(TriangleVarying in [[stage_in]],
    constant DrawUniforms& u [[buffer(1)]], texture2d<ushort,access::read> bank0 [[texture(0)]],
    texture2d<ushort,access::read> bank1 [[texture(1)]]) {
    FragmentContext c(u,bank0,bank1,in.position);
    c.fsViewVertex=in.viewVertex; c.fsViewNormal=in.viewNormal; c.fsTexCoord=in.texcoord;
    c.fsColor=in.colour; c.fsFixedShade=in.fixedShade; c.fsLODBase=in.lodBase; c.fsDiscardPoly=in.discardPoly;
    c.shadeTriangle(); c.result.depth=clamp(c.result.depth,0.0f,1.0f); return c.result;
}
SceneResult shadeQuadFragment(QuadFragmentVarying in,
    constant DrawUniforms& u, texture2d<ushort,access::read> bank0,
    texture2d<ushort,access::read> bank1) {
    FragmentContext c(u,bank0,bank1,in.position);
    c.fs_in.v[0]=in.v0; c.fs_in.v[1]=in.v1; c.fs_in.v[2]=in.v2; c.fs_in.v[3]=in.v3;
    for (uint i=0;i<4;++i) {
        c.fs_in.area[i]=in.area[i]; c.fs_in.oneOverW[i]=in.oneOverW[i];
        c.fs_in.viewVertex[i]=float3(in.viewX[i],in.viewY[i],in.viewZ[i]);
        c.fs_in.viewNormal[i]=float3(in.normalX[i],in.normalY[i],in.normalZ[i]);
        c.fs_in.texCoord[i]=float2(in.texU[i],in.texV[i]); c.fs_in.fixedShade[i]=in.fixedShade[i];
    }
    c.fs_in.color=in.colour; c.fs_in.LODBase=in.lodBase; c.fs_in.barycentricCoords=in.barycentricCoords;
    c.shadeQuad(); c.result.depth=clamp(c.result.depth,0.0f,1.0f); return c.result;
}

fragment SceneResult real3d_quad_fragment(QuadFragmentVarying in [[stage_in]],
    constant DrawUniforms& u [[buffer(1)]], texture2d<ushort,access::read> bank0 [[texture(0)]],
    texture2d<ushort,access::read> bank1 [[texture(1)]]) {
    return shadeQuadFragment(in,u,bank0,bank1);
}
fragment ConservativeSceneResult real3d_quad_fragment_culled(QuadFragmentVarying in [[stage_in]],
    constant DrawUniforms& u [[buffer(1)]], texture2d<ushort,access::read> bank0 [[texture(0)]],
    texture2d<ushort,access::read> bank1 [[texture(1)]]) {
    SceneResult r=shadeQuadFragment(in,u,bank0,bank1);
    return {r.colour,r.trans1,r.trans2,r.depth};
}
