#include "TileCache.hpp"
#include "TileImage.hpp"

#include <utility>

namespace pager {

bool TileKey::operator==(const TileKey& other) const {
    return page == other.page && scaleBand == other.scaleBand && column == other.column && row == other.row;
}

std::size_t TileKeyHash::operator()(const TileKey& key) const {
    std::uint64_t value = static_cast<std::uint32_t>(key.page);
    value = value * 0x9E3779B97F4A7C15ull + static_cast<std::uint32_t>(key.scaleBand);
    value = value * 0x9E3779B97F4A7C15ull + static_cast<std::uint32_t>(key.column);
    value = value * 0x9E3779B97F4A7C15ull + static_cast<std::uint32_t>(key.row);
    value ^= value >> 29;
    return static_cast<std::size_t>(value);
}

TileCache::TileCache(std::size_t byteCap) : byteCap_(byteCap) {}

void TileCache::setByteCap(std::size_t byteCap) {
    byteCap_ = byteCap;
    evictIfNeeded();
}

void TileCache::clear() {
    entries_.clear();
    index_.clear();
    bytes_ = 0;
}

void TileCache::insert(TileImage image) {
    const auto existing = index_.find(image.key);
    if (existing != index_.end()) {
        bytes_ -= existing->second->byteCount();
        entries_.erase(existing->second);
        index_.erase(existing);
    }
    bytes_ += image.byteCount();
    entries_.push_front(std::move(image));
    index_[entries_.front().key] = entries_.begin();
    evictIfNeeded();
}

const TileImage* TileCache::find(const TileKey& key) const {
    const auto found = index_.find(key);
    return found == index_.end() ? nullptr : &*found->second;
}

const TileImage* TileCache::touch(const TileKey& key) {
    const auto found = index_.find(key);
    if (found == index_.end()) {
        return nullptr;
    }
    entries_.splice(entries_.begin(), entries_, found->second);
    return &entries_.front();
}

void TileCache::evictIfNeeded() {
    // Never evict the newest entry: a single tile larger than the cap must still be usable.
    while (bytes_ > byteCap_ && entries_.size() > 1) {
        const TileImage& oldest = entries_.back();
        bytes_ -= oldest.byteCount();
        index_.erase(oldest.key);
        entries_.pop_back();
    }
}

CGImageRef CreateTileCGImage(const TileImage& tile) {
    CGImageRef image = tile.image.get();
    return image == nullptr ? nullptr : CGImageRetain(image);
}

}  // namespace pager
