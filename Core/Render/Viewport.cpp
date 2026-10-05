#include "Viewport.hpp"

#include "Zoom.hpp"

#include <CoreGraphics/CGBitmapContext.h>
#include <CoreGraphics/CGColorSpace.h>
#include <CoreGraphics/CGImage.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_set>

namespace pager {
namespace {

void FillWhite(CGContextRef context, int width, int height) {
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
}

}  // namespace

Viewport::Viewport(std::size_t cacheBytes) : cache_(cacheBytes), worker_([this]() { workerMain(); }) {}

Viewport::~Viewport() {
    {
        std::lock_guard<std::mutex> clientLock(clientMutex_);
        client_ = nullptr;
    }
    {
        std::lock_guard<std::mutex> queueLock(queueMutex_);
        stop_ = true;
        source_ = nullptr;
        jobs_.clear();
    }
    queueCV_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

void Viewport::setPages(std::vector<PageGeometry> pages) {
    pages_ = std::move(pages);
    // Document space is always PDF displayed-points. Zoom only changes raster density.
    layout_.rebuild(pages_, 1.0);
    {
        std::lock_guard<std::mutex> cacheLock(cacheMutex_);
        cache_.clear();
    }
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    jobs_.clear();
}

void Viewport::setScale(double scale) {
    scale_ = ClampScale(scale);
    // Keep the layout and the existing tile cache. The scroll view scales the
    // current rasters on the GPU; new tiles refine them without a blank frame.
}

void Viewport::setScreenScale(double screenScale) {
    screenScale_ = screenScale <= 0 ? 1 : screenScale;
}

void Viewport::setVisibleRect(Rect visible) { visible_ = visible; }

void Viewport::setClient(TileClient* client) {
    std::lock_guard<std::mutex> clientLock(clientMutex_);
    client_ = client;
}

const PageGeometry* Viewport::geometry(int index) const {
    for (const PageGeometry& page : pages_) {
        if (page.index == index) {
            return &page;
        }
    }
    return nullptr;
}

std::vector<TileSlot> Viewport::visibleSlots() const {
    std::vector<TileSlot> slots;
    if (visible_.width <= 0 || visible_.height <= 0) {
        return slots;
    }
    // Prefetch a generous margin so tiles are already rendered before they scroll on screen.
    Rect padded = visible_;
    padded.x -= 256;
    padded.y -= 256;
    padded.width += 512;
    padded.height += 512;
    const int band = ScaleKeyForZoom(scale_);
    const double pixelsPerPoint = std::max(0.05, scale_) * screenScale_;
    const double tilePoints = static_cast<double>(kTilePixels) / pixelsPerPoint;
    if (tilePoints <= 0) {
        return slots;
    }
    for (const PageFrame& frame : layout_.pages()) {
        if (!frame.frame.intersects(padded)) {
            continue;
        }
        const int columns = std::max(1, static_cast<int>(std::ceil(frame.frame.width / tilePoints)));
        const int rows = std::max(1, static_cast<int>(std::ceil(frame.frame.height / tilePoints)));
        for (int row = 0; row < rows; ++row) {
            for (int column = 0; column < columns; ++column) {
                TileKey key{frame.index, band, column, row};
                const Rect tileRect = tileDocumentFrame(key);
                if (!tileRect.intersects(padded)) {
                    continue;
                }
                TileSlot slot;
                slot.key = key;
                slot.documentFrame = tileRect;
                {
                    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
                    slot.ready = cache_.find(slot.key) != nullptr;
                }
                slots.push_back(slot);
            }
        }
    }
    return slots;
}

Rect Viewport::tileDocumentFrame(const TileKey& key) const {
    const double zoom = std::max(0.05, key.scaleBand / 100.0);
    const double pixelsPerPoint = zoom * std::max(0.05, screenScale_);
    const double tilePoints = static_cast<double>(kTilePixels) / pixelsPerPoint;
    const Rect page = layout_.pageFrame(key.page);
    return Rect{page.x + key.column * tilePoints, page.y + key.row * tilePoints, tilePoints, tilePoints};
}

void Viewport::requestVisibleTiles(PageRasterSource& source) {
    const int band = ScaleKeyForZoom(scale_);
    const double pixelsPerPoint = std::max(0.05, scale_) * screenScale_;
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    source_ = &source;
    const std::vector<TileSlot> slots = visibleSlots();
    // Drop queued jobs that are no longer visible: after a fast scroll the worker should
    // render what is on screen now, not plow through a backlog of stale tiles first.
    std::unordered_set<TileKey, TileKeyHash> wanted;
    wanted.reserve(slots.size());
    for (const TileSlot& slot : slots) {
        wanted.insert(slot.key);
    }
    jobs_.erase(std::remove_if(jobs_.begin(), jobs_.end(),
                               [&](const Job& job) { return wanted.find(job.key) == wanted.end(); }),
                jobs_.end());
    for (const TileSlot& slot : slots) {
        if (slot.ready) {
            continue;
        }
        const bool queued = std::any_of(jobs_.begin(), jobs_.end(),
                                        [&](const Job& job) { return job.key == slot.key; });
        if (queued) {
            continue;
        }
        const PageGeometry* page = geometry(slot.key.page);
        if (page == nullptr) {
            continue;
        }
        const Size displayed = DisplayedSize(*page);
        Job job;
        job.key = slot.key;
        job.pageWidth = displayed.width;
        job.pageHeight = displayed.height;
        job.pixelsPerPoint = pixelsPerPoint;
        jobs_.push_back(job);
    }
    queueCV_.notify_all();
}

bool Viewport::copyTile(const TileKey& key, TileImage* image) const {
    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
    const TileImage* found = cache_.find(key);
    if (found == nullptr || image == nullptr) {
        return found != nullptr;
    }
    *image = *found;
    return true;
}

void Viewport::invalidateTiles() {
    {
        std::lock_guard<std::mutex> cacheLock(cacheMutex_);
        cache_.clear();
    }
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    jobs_.clear();
}

void Viewport::workerMain() {
    for (;;) {
        Job job;
        PageRasterSource* source = nullptr;
        {
            std::unique_lock<std::mutex> queueLock(queueMutex_);
            queueCV_.wait(queueLock, [&]() { return stop_ || !jobs_.empty(); });
            if (stop_ && jobs_.empty()) {
                return;
            }
            if (jobs_.empty() || source_ == nullptr) {
                if (stop_) {
                    return;
                }
                jobs_.clear();
                continue;
            }
            job = jobs_.front();
            jobs_.pop_front();
            source = source_;
        }
        TileImage image = render(*source, job);
        if (!image.bgra.empty()) {
            {
                std::lock_guard<std::mutex> cacheLock(cacheMutex_);
                cache_.insert(image);
            }
            publish(std::move(image));
        }
    }
}

TileImage Viewport::render(PageRasterSource& source, const Job& job) {
    TileImage image;
    image.key = job.key;
    image.width = kTilePixels;
    image.height = kTilePixels;
    image.bytesPerRow = kTilePixels * 4;
    image.bgra.assign(static_cast<std::size_t>(image.bytesPerRow * image.height), 255);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(image.bgra.data(), static_cast<size_t>(image.width),
                                                 static_cast<size_t>(image.height), 8, image.bytesPerRow, colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (context == nullptr) {
        image.bgra.clear();
        return image;
    }
    FillWhite(context, image.width, image.height);
    CGContextSaveGState(context);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextTranslateCTM(context, 0, image.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, -job.key.column * kTilePixels, -job.key.row * kTilePixels);
    CGContextScaleCTM(context, job.pixelsPerPoint, job.pixelsPerPoint);
    source.drawPage(job.key.page, context, job.pageWidth, job.pageHeight);
    CGContextRestoreGState(context);
    CGContextRelease(context);
    return image;
}

void Viewport::publish(TileImage image) {
    std::lock_guard<std::mutex> clientLock(clientMutex_);
    if (client_ != nullptr) {
        client_->tileReady(std::move(image));
    }
}

}  // namespace pager
