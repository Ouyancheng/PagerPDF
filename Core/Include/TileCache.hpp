#pragma once

#include <CoreGraphics/CGImage.h>

#include <cstddef>
#include <cstdint>
#include <list>
#include <unordered_map>

namespace pager {

struct TileKey {
    int page = 0;
    int scaleBand = 0;
    int column = 0;
    int row = 0;

    bool operator==(const TileKey& other) const;
    bool operator!=(const TileKey& other) const { return !(*this == other); }
};

struct TileKeyHash {
    std::size_t operator()(const TileKey& key) const;
};

// Owning, copyable CGImageRef. Copies retain, so a tile can sit in the cache, a layer and a
// pending main-queue block at once without duplicating pixels.
class ImageHandle {
public:
    ImageHandle() = default;
    // Adopts a +1 reference.
    explicit ImageHandle(CGImageRef adopted) : image_(adopted) {}
    ImageHandle(const ImageHandle& other) : image_(other.image_) {
        if (image_ != nullptr) {
            CGImageRetain(image_);
        }
    }
    ImageHandle(ImageHandle&& other) noexcept : image_(other.image_) { other.image_ = nullptr; }
    ImageHandle& operator=(ImageHandle other) noexcept {
        CGImageRef previous = image_;
        image_ = other.image_;
        other.image_ = previous;
        return *this;
    }
    ~ImageHandle() {
        if (image_ != nullptr) {
            CGImageRelease(image_);
        }
    }

    CGImageRef get() const { return image_; }
    explicit operator bool() const { return image_ != nullptr; }

private:
    CGImageRef image_ = nullptr;
};

struct TileImage {
    TileKey key;
    int width = 0;
    int height = 0;
    ImageHandle image;
    // Viewport generation the tile was rendered for; stale generations must be dropped.
    std::uint64_t generation = 0;

    std::size_t byteCount() const { return static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * 4; }
};

// Least-recently-used tile store bounded by decoded byte size.
class TileCache {
public:
    explicit TileCache(std::size_t byteCap);

    void setByteCap(std::size_t byteCap);
    std::size_t byteCap() const { return byteCap_; }
    void clear();
    void insert(TileImage image);
    // Lookup without changing recency.
    const TileImage* find(const TileKey& key) const;
    // Lookup that marks the tile as recently used.
    const TileImage* touch(const TileKey& key);
    bool contains(const TileKey& key) const { return index_.find(key) != index_.end(); }
    std::size_t byteCount() const { return bytes_; }
    std::size_t count() const { return entries_.size(); }

private:
    void evictIfNeeded();

    std::size_t byteCap_;
    std::size_t bytes_ = 0;
    // Front = most recently used.
    std::list<TileImage> entries_;
    std::unordered_map<TileKey, std::list<TileImage>::iterator, TileKeyHash> index_;
};

}  // namespace pager
