#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

namespace pager {

struct TileKey {
    int page = 0;
    int scaleBand = 0;
    int column = 0;
    int row = 0;

    bool operator==(const TileKey& other) const;
};

struct TileKeyHash {
    std::size_t operator()(const TileKey& key) const;
};

struct TileImage {
    TileKey key;
    int width = 0;
    int height = 0;
    int bytesPerRow = 0;
    std::vector<std::uint8_t> bgra;
};

class TileCache {
public:
    explicit TileCache(std::size_t byteCap);

    void setByteCap(std::size_t byteCap);
    void clear();
    void insert(TileImage image);
    const TileImage* find(const TileKey& key) const;
    std::size_t byteCount() const { return bytes_; }
    std::size_t count() const { return order_.size(); }

private:
    void evictIfNeeded();

    std::size_t byteCap_;
    std::size_t bytes_ = 0;
    std::vector<TileKey> order_;
    std::vector<TileImage> images_;
};

}  // namespace pager
