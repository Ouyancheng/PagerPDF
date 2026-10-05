#include "TileCache.hpp"
#include "TileImage.hpp"

#include <CoreGraphics/CGColorSpace.h>
#include <CoreGraphics/CGDataProvider.h>
#include <CoreGraphics/CGImage.h>

#include <algorithm>
#include <utility>

namespace pager {

bool TileKey::operator==(const TileKey& other) const {
    return page == other.page && scaleBand == other.scaleBand && column == other.column && row == other.row;
}

std::size_t TileKeyHash::operator()(const TileKey& key) const {
    std::size_t value = static_cast<std::size_t>(key.page) * 1315423911u;
    value ^= static_cast<std::size_t>(key.scaleBand) << 24;
    value ^= static_cast<std::size_t>(key.column) << 12;
    value ^= static_cast<std::size_t>(key.row);
    return value;
}

TileCache::TileCache(std::size_t byteCap) : byteCap_(byteCap) {}

void TileCache::setByteCap(std::size_t byteCap) {
    byteCap_ = byteCap;
    evictIfNeeded();
}

void TileCache::clear() {
    order_.clear();
    images_.clear();
    bytes_ = 0;
}

void TileCache::insert(TileImage image) {
    const auto existing = std::find(order_.begin(), order_.end(), image.key);
    if (existing != order_.end()) {
        const auto index = static_cast<std::size_t>(existing - order_.begin());
        bytes_ -= images_[index].bgra.size();
        images_.erase(images_.begin() + static_cast<std::ptrdiff_t>(index));
        order_.erase(existing);
    }
    bytes_ += image.bgra.size();
    order_.push_back(image.key);
    images_.push_back(std::move(image));
    evictIfNeeded();
}

const TileImage* TileCache::find(const TileKey& key) const {
    const auto found = std::find(order_.begin(), order_.end(), key);
    if (found == order_.end()) {
        return nullptr;
    }
    return &images_[static_cast<std::size_t>(found - order_.begin())];
}

void TileCache::evictIfNeeded() {
    while (bytes_ > byteCap_ && !order_.empty()) {
        bytes_ -= images_.front().bgra.size();
        order_.erase(order_.begin());
        images_.erase(images_.begin());
    }
}

CGImageRef CreateTileCGImage(const TileImage& tile) {
    if (tile.bgra.empty() || tile.width <= 0 || tile.height <= 0) {
        return nullptr;
    }
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, tile.bgra.data(), static_cast<CFIndex>(tile.bgra.size()));
    if (data == nullptr) {
        return nullptr;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(static_cast<size_t>(tile.width), static_cast<size_t>(tile.height), 8, 32,
                                     static_cast<size_t>(tile.bytesPerRow), colorSpace,
                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, nullptr,
                                     false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return image;
}

}  // namespace pager
