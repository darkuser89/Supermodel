// Native GPU half of the current New3D renderer. GPL-3.0-or-later.
#pragma once
#include "Context.h"
#include <cstddef>
#include <cstdint>

namespace New3D { struct FVertex; struct Viewport; struct Model; struct Mesh; }
namespace SupermodelMetal4 {
class SceneRenderer final {
public:
    explicit SceneRenderer(Context& context);
    ~SceneRenderer();
    SceneRenderer(const SceneRenderer&) = delete;
    SceneRenderer& operator=(const SceneRenderer&) = delete;

    bool Resize(unsigned width, unsigned height);
    bool UploadTextures(unsigned page, unsigned level, unsigned x, unsigned y,
        unsigned width, unsigned height, const uint16_t* sheet);
    bool IsOccluded() const;
    bool BeginScene(const New3D::FVertex* rom, size_t romCount,
        const New3D::FVertex* ram, size_t ramCount, bool quads, bool allowOcclusion = false);
    bool BeginLayer(unsigned layer, bool clearDepth);
    bool Draw(const New3D::Viewport& viewport, const New3D::Model& model, const New3D::Mesh& mesh);
    void EndLayer();
    bool StoreDepth();
    void InvalidateRomCache();
    bool ReadLos(int x, int y, float& depth, uint8_t& stencil);
    bool Fog(const New3D::Viewport& viewport, const float colour[4], float attenuation,
        float ambient, const float spotColour[3], const float ellipse[4]);
    bool Composite();
    bool WhiteFlash();
private:
    struct State;
    std::unique_ptr<State> m_state;
};
}
