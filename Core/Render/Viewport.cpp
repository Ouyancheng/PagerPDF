#include "Viewport.hpp"

#include "Zoom.hpp"

#include <CoreGraphics/CGBitmapContext.h>
#include <CoreGraphics/CGColorSpace.h>
#include <CoreGraphics/CGImage.h>

#include <algorithm>
#include <cmath>

namespace pager {
namespace {

constexpr double kPrefetchFraction = 0.35;

CGColorSpaceRef SRGB() {
    static CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return space;
}

double DistanceSquared(Point a, Point b) {
    const double dx = a.x - b.x;
    const double dy = a.y - b.y;
    return dx * dx + dy * dy;
}

}  // namespace

Viewport::Viewport(std::size_t cacheBytes, int workerCount) : cache_(cacheBytes) {
    const int count = std::max(1, workerCount);
    for (int index = 0; index < count; ++index) {
        workers_.emplace_back([this]() { workerMain(); });
    }
}

Viewport::~Viewport() { stop(); }

void Viewport::stop() {
    {
        std::lock_guard<std::mutex> clientLock(clientMutex_);
        client_ = nullptr;
    }
    {
        std::lock_guard<std::mutex> queueLock(queueMutex_);
        stop_ = true;
        jobs_.clear();
    }
    queueCV_.notify_all();
    for (std::thread& worker : workers_) {
        if (worker.joinable()) {
            worker.join();
        }
    }
    workers_.clear();
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    source_ = nullptr;
}

void Viewport::bumpGenerationLocked() {
    generation_.fetch_add(1);
    jobs_.clear();
    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
    cache_.clear();
}

void Viewport::setPages(std::vector<PageGeometry> pages) {
    pages_ = std::move(pages);
    geometrySlot_.clear();
    for (std::size_t slot = 0; slot < pages_.size(); ++slot) {
        const int index = pages_[slot].index;
        if (index < 0) {
            continue;
        }
        if (static_cast<std::size_t>(index) >= geometrySlot_.size()) {
            geometrySlot_.resize(static_cast<std::size_t>(index) + 1, -1);
        }
        geometrySlot_[static_cast<std::size_t>(index)] = static_cast<int>(slot);
    }
    // Document space is always PDF displayed-points. Zoom only changes raster density.
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    rebuildLayoutLocked();
    bumpGenerationLocked();
}

void Viewport::rebuildLayoutLocked() {
    const int pageCount = static_cast<int>(pages_.size());
    spec_ = spec_.normalized();
    const int sheets = SheetCount(pageCount, spec_);
    if (sheets <= 0) {
        sheet_ = 0;
    } else {
        sheet_ = std::clamp(sheet_, 0, sheets - 1);
    }
    layout_.rebuild(pages_, spec_, sheet_, 1.0);
}

void Viewport::setViewSpec(ViewSpec spec) {
    spec = spec.normalized();
    if (spec == spec_) {
        return;
    }
    spec_ = spec;
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    rebuildLayoutLocked();
    bumpGenerationLocked();
}

void Viewport::setSheet(int sheet) {
    const int pageCount = static_cast<int>(pages_.size());
    const int count = SheetCount(pageCount, spec_);
    const int next = count <= 0 ? 0 : std::clamp(sheet, 0, count - 1);
    if (next == sheet_ && layout_.sheet() == next) {
        return;
    }
    sheet_ = next;
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    rebuildLayoutLocked();
    bumpGenerationLocked();
}

void Viewport::setScale(double scale) {
    scale_ = ClampScale(scale);
    // Keep the layout and the existing tile cache. The scroll view scales the
    // current rasters on the GPU; new tiles refine them without a blank frame.
}

void Viewport::setScreenScale(double screenScale) {
    const double next = screenScale <= 0 ? 1 : screenScale;
    if (std::fabs(next - screenScale_) < 1e-6) {
        return;
    }
    screenScale_ = next;
    // Tile keys do not encode the screen scale, so every raster is now the wrong density.
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    bumpGenerationLocked();
}

void Viewport::setVisibleRect(Rect visible) { visible_ = visible; }

void Viewport::setClient(TileClient* client) {
    std::lock_guard<std::mutex> clientLock(clientMutex_);
    client_ = client;
}

void Viewport::setSource(PageRasterSource* source) {
    std::unique_lock<std::mutex> queueLock(queueMutex_);
    if (source == source_) {
        return;
    }
    const bool replacing = source_ != nullptr;
    source_ = source;
    if (replacing) {
        // Tiles from the previous source are the wrong document.
        bumpGenerationLocked();
        idleCV_.wait(queueLock, [&]() { return active_ == 0; });
    }
}

int Viewport::band() const { return ScaleKeyForZoom(scale_); }

int Viewport::baseBand() const { return band() > kBaseBand ? kBaseBand : -1; }

const PageGeometry* Viewport::geometry(int index) const {
    if (index < 0 || static_cast<std::size_t>(index) >= geometrySlot_.size()) {
        return nullptr;
    }
    const int slot = geometrySlot_[static_cast<std::size_t>(index)];
    return slot < 0 ? nullptr : &pages_[static_cast<std::size_t>(slot)];
}

Rect Viewport::prefetchRect() const {
    if (visible_.empty()) {
        return visible_;
    }
    const double padX = visible_.width * kPrefetchFraction;
    const double padY = visible_.height * kPrefetchFraction;
    return Rect{visible_.x - padX, visible_.y - padY, visible_.width + padX * 2, visible_.height + padY * 2};
}

double Viewport::pixelsPerPoint(int band) const {
    return ZoomForScaleKey(band) * std::max(0.05, screenScale_);
}

void Viewport::tilePixelSize(const TileKey& key, const Rect& pageFrame, int* width, int* height) const {
    const double ppp = pixelsPerPoint(key.scaleBand);
    // Edge tiles stop at the page edge instead of carrying a full 512px square of white.
    const int pageWidth = static_cast<int>(std::ceil(pageFrame.width * ppp - 1e-6));
    const int pageHeight = static_cast<int>(std::ceil(pageFrame.height * ppp - 1e-6));
    *width = std::clamp(pageWidth - key.column * kTilePixels, 0, kTilePixels);
    *height = std::clamp(pageHeight - key.row * kTilePixels, 0, kTilePixels);
}

Rect Viewport::tileDocumentFrame(const TileKey& key) const {
    const PageFrame* frame = layout_.frameFor(key.page);
    if (frame == nullptr) {
        return {};
    }
    const double ppp = pixelsPerPoint(key.scaleBand);
    int width = 0;
    int height = 0;
    tilePixelSize(key, frame->frame, &width, &height);
    const double tilePoints = kTilePixels / ppp;
    return Rect{frame->frame.x + key.column * tilePoints, frame->frame.y + key.row * tilePoints, width / ppp,
                height / ppp};
}

std::vector<TileSlot> Viewport::slots(int band, Rect documentRect) const {
    std::vector<TileSlot> result;
    if (documentRect.empty() || band <= 0) {
        return result;
    }
    const double tilePoints = kTilePixels / pixelsPerPoint(band);
    for (const int pageIndex : layout_.pagesIntersecting(documentRect)) {
        const PageFrame* frame = layout_.frameFor(pageIndex);
        if (frame == nullptr) {
            continue;
        }
        const Rect page = frame->frame;
        const Rect area = page.intersection(documentRect);
        if (area.empty()) {
            continue;
        }
        const int columns = std::max(1, static_cast<int>(std::ceil(page.width / tilePoints - 1e-9)));
        const int rows = std::max(1, static_cast<int>(std::ceil(page.height / tilePoints - 1e-9)));
        const int firstColumn = std::clamp(static_cast<int>(std::floor((area.x - page.x) / tilePoints)), 0, columns - 1);
        const int lastColumn =
            std::clamp(static_cast<int>(std::floor((area.x + area.width - page.x) / tilePoints)), 0, columns - 1);
        const int firstRow = std::clamp(static_cast<int>(std::floor((area.y - page.y) / tilePoints)), 0, rows - 1);
        const int lastRow =
            std::clamp(static_cast<int>(std::floor((area.y + area.height - page.y) / tilePoints)), 0, rows - 1);
        for (int row = firstRow; row <= lastRow; ++row) {
            for (int column = firstColumn; column <= lastColumn; ++column) {
                TileSlot slot;
                slot.key = TileKey{pageIndex, band, column, row};
                slot.documentFrame = tileDocumentFrame(slot.key);
                if (slot.documentFrame.empty()) {
                    continue;
                }
                result.push_back(slot);
            }
        }
    }
    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
    for (TileSlot& slot : result) {
        slot.ready = cache_.contains(slot.key);
    }
    return result;
}

std::vector<TileSlot> Viewport::visibleSlots() const { return slots(band(), prefetchRect()); }

bool Viewport::makeJob(const TileSlot& slot, Job* job) const {
    const PageGeometry* page = geometry(slot.key.page);
    const PageFrame* frame = layout_.frameFor(slot.key.page);
    if (page == nullptr || frame == nullptr) {
        return false;
    }
    const Size displayed = DisplayedSize(*page);
    job->key = slot.key;
    job->pageWidth = displayed.width;
    job->pageHeight = displayed.height;
    job->pixelsPerPoint = pixelsPerPoint(slot.key.scaleBand);
    tilePixelSize(slot.key, frame->frame, &job->pixelWidth, &job->pixelHeight);
    job->generation = generation_.load();
    return job->pixelWidth > 0 && job->pixelHeight > 0;
}

void Viewport::requestVisibleTiles(PageRasterSource& source) {
    setSource(&source);
    requestTiles(true, nullptr);
}

void Viewport::requestTiles(bool currentBand, const TileKeySet* displayed) {
    if (visible_.empty()) {
        return;
    }
    const int current = band();
    const int base = baseBand();
    const Point center = visible_.center();
    std::vector<TileSlot> ordered;
    if (currentBand) {
        std::vector<TileSlot> onScreen = slots(current, visible_);
        std::sort(onScreen.begin(), onScreen.end(), [&](const TileSlot& a, const TileSlot& b) {
            return DistanceSquared(a.documentFrame.center(), center) < DistanceSquared(b.documentFrame.center(), center);
        });
        ordered.insert(ordered.end(), onScreen.begin(), onScreen.end());
    }
    if (base > 0) {
        const Rect reach{visible_.x, visible_.y - visible_.height, visible_.width, visible_.height * 3};
        for (const int pageIndex : layout_.pagesIntersecting(reach)) {
            const std::vector<TileSlot> pageSlots = slots(base, layout_.pageFrame(pageIndex));
            ordered.insert(ordered.end(), pageSlots.begin(), pageSlots.end());
        }
    }
    if (currentBand) {
        std::vector<TileSlot> prefetch = slots(current, prefetchRect());
        std::sort(prefetch.begin(), prefetch.end(), [&](const TileSlot& a, const TileSlot& b) {
            return DistanceSquared(a.documentFrame.center(), center) < DistanceSquared(b.documentFrame.center(), center);
        });
        ordered.insert(ordered.end(), prefetch.begin(), prefetch.end());
    }

    std::deque<Job> next;
    TileKeySet queued;
    {
        std::lock_guard<std::mutex> queueLock(queueMutex_);
        if (source_ == nullptr || stop_) {
            return;
        }
        std::lock_guard<std::mutex> cacheLock(cacheMutex_);
        for (const TileSlot& slot : ordered) {
            if (!queued.insert(slot.key).second) {
                continue;
            }
            // Refresh recency so on-screen tiles are the last thing the LRU evicts.
            if (cache_.touch(slot.key) != nullptr) {
                continue;
            }
            if (inflight_.count(slot.key) != 0 || (displayed != nullptr && displayed->count(slot.key) != 0)) {
                continue;
            }
            Job job;
            if (makeJob(slot, &job)) {
                next.push_back(job);
            }
        }
        // Replacing the queue wholesale drops tiles that scrolled away before they rendered.
        jobs_ = std::move(next);
    }
    queueCV_.notify_all();
}

bool Viewport::copyTile(const TileKey& key, TileImage* image) const {
    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
    const TileImage* found = cache_.touch(key);
    if (found == nullptr || image == nullptr) {
        return found != nullptr;
    }
    *image = *found;
    return true;
}

void Viewport::invalidateTiles() {
    std::lock_guard<std::mutex> queueLock(queueMutex_);
    bumpGenerationLocked();
}

void Viewport::trimCache() {
    TileKeySet keep;
    for (const TileSlot& slot : visibleSlots()) {
        keep.insert(slot.key);
    }
    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
    std::vector<TileImage> kept;
    for (const TileKey& key : keep) {
        if (const TileImage* found = cache_.find(key)) {
            kept.push_back(*found);
        }
    }
    cache_.clear();
    for (TileImage& image : kept) {
        cache_.insert(std::move(image));
    }
}

std::size_t Viewport::cachedBytes() const {
    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
    return cache_.byteCount();
}

void Viewport::workerMain() {
    for (;;) {
        Job job;
        PageRasterSource* source = nullptr;
        {
            std::unique_lock<std::mutex> queueLock(queueMutex_);
            queueCV_.wait(queueLock, [&]() { return stop_ || (!jobs_.empty() && source_ != nullptr); });
            if (stop_) {
                return;
            }
            job = jobs_.front();
            jobs_.pop_front();
            if (job.generation != generation_.load()) {
                continue;
            }
            inflight_.insert(job.key);
            source = source_;
            ++active_;
        }
        TileImage image = render(*source, job);
        bool current = false;
        {
            std::lock_guard<std::mutex> queueLock(queueMutex_);
            --active_;
            inflight_.erase(job.key);
            current = !stop_ && job.generation == generation_.load() && image.image;
            if (current) {
                // Inserted under the queue lock so an invalidation cannot slip in between the
                // generation check and the insert and leave a stale tile cached.
                std::lock_guard<std::mutex> cacheLock(cacheMutex_);
                cache_.insert(image);
            }
        }
        idleCV_.notify_all();
        if (current) {
            publish(std::move(image));
        }
    }
}

TileImage Viewport::render(PageRasterSource& source, const Job& job) {
    TileImage image;
    image.key = job.key;
    image.width = job.pixelWidth;
    image.height = job.pixelHeight;
    image.generation = job.generation;
    // Opaque: the page is always painted white first, and opaque layers composite cheaper.
    const CGBitmapInfo info =
        static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipFirst) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little);
    CGContextRef context = CGBitmapContextCreate(nullptr, static_cast<size_t>(image.width),
                                                 static_cast<size_t>(image.height), 8, 0, SRGB(), info);
    if (context == nullptr) {
        return image;
    }
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, image.width, image.height));
    CGContextSaveGState(context);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextTranslateCTM(context, 0, image.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, -job.key.column * kTilePixels, -job.key.row * kTilePixels);
    CGContextScaleCTM(context, job.pixelsPerPoint, job.pixelsPerPoint);
    source.drawPage(job.key.page, context, job.pageWidth, job.pageHeight);
    CGContextRestoreGState(context);
    // Copy-on-write: releasing the context right after hands its buffer to the image.
    image.image = ImageHandle(CGBitmapContextCreateImage(context));
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
