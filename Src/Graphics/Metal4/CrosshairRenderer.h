#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
namespace SupermodelMetal4 {
class CrosshairRenderer final {
public:
    CrosshairRenderer();
    ~CrosshairRenderer();
    bool Upload(unsigned player,const uint8_t* rgba,unsigned width,unsigned height,size_t pitch);
    bool Draw(const float* xyz,size_t count,const float* uv,size_t uvCount,const float* matrix,
        const float* colour,bool textured,unsigned player,unsigned x,unsigned y,unsigned width,unsigned height);
private:
    struct State;
    std::unique_ptr<State> m_state;
};
}
