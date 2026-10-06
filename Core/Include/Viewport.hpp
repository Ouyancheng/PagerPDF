#pragma once

#include "Layout.hpp"
#include "PageRasterSource.hpp"
#include "TileCache.hpp"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <unordered_set>
#include <vector>

namespace pager {

struct TileSlot {
    TileKey key;
    Rect documentFrame;
    bool ready = false;
};

using TileKeySet = std::unordered_set<TileKey, TileKeyHash>;

class TileClient {
public:
    virtual ~TileClient() = default;
    // Called on a render thread.
    virtual void tileReady(TileImage image) = 0;
};

class Viewport {
public:
    static constexpr int kTilePixels = 512;
    // Low-resolution whole-page rasters shown under the sharp tiles so fast scrolls and
    // zoom-outs never reveal a blank page.
    static constexpr int kBaseBand = 30;

    explicit Viewport(std::size_t cacheBytes = 160ull * 1024ull * 1024ull, int workerCount = 2);
    ~Viewport();

    Viewport(const Viewport&) = delete;
    Viewport& operator=(const Viewport&) = delete;

    void setPages(std::vector<PageGeometry> pages);
    void setViewSpec(ViewSpec spec);
    void setSheet(int sheet);
    const ViewSpec& viewSpec() const { return spec_; }
    int sheet() const { return sheet_; }
    // Raster / pinch zoom. Does not rebuild page frames — those stay in PDF points
    // so the canvas size is stable and UIScrollView can zoom without a flash.
    void setScale(double scale);
    void setScreenScale(double screenScale);
    void setVisibleRect(Rect visible);
    void setClient(TileClient* client);
    // Blocks until renders that were using the previous source have finished, so the caller
    // may destroy the old source as soon as this returns.
    void setSource(PageRasterSource* source);
    // Joins the render threads. Idempotent; called by the destructor.
    void stop();

    const Layout& layout() const { return layout_; }
    double scale() const { return scale_; }
    int band() const;
    // kBaseBand while zoomed in past it, otherwise -1 (the current band is cheap enough).
    int baseBand() const;
    double screenScale() const { return screenScale_; }
    Rect visibleRect() const { return visible_; }
    // Visible rect plus a prefetch margin that is a fixed fraction of the screen, so the
    // number of prefetched tiles does not explode at high zoom.
    Rect prefetchRect() const;
    const std::vector<PageGeometry>& pages() const { return pages_; }
    const PageGeometry* geometry(int index) const;
    std::uint64_t generation() const { return generation_.load(); }

    std::vector<TileSlot> slots(int band, Rect documentRect) const;
    // Current band, prefetch rect.
    std::vector<TileSlot> visibleSlots() const;
    // Document-space rect for a tile key. Valid for any band; layout is always PDF points,
    // so an old zoom's rasters still sit on the same page.
    Rect tileDocumentFrame(const TileKey& key) const;

    void requestVisibleTiles(PageRasterSource& source);
    // Queues missing tiles in priority order: on-screen tiles nearest the centre, then base
    // rasters, then prefetch. `displayed` lists tiles already on screen that need no render
    // even if the cache dropped them. Pass currentBand = false during a pinch so only cheap
    // base rasters are rendered.
    void requestTiles(bool currentBand = true, const TileKeySet* displayed = nullptr);
    bool copyTile(const TileKey& key, TileImage* image) const;
    // Drops every cached and queued tile (e.g. after the screen scale changed).
    void invalidateTiles();
    // Memory pressure: keep only what the current prefetch rect needs.
    void trimCache();
    std::size_t cachedBytes() const;

private:
    struct Job {
        TileKey key;
        double pageWidth = 0;
        double pageHeight = 0;
        double pixelsPerPoint = 1;
        int pixelWidth = 0;
        int pixelHeight = 0;
        std::uint64_t generation = 0;
    };

    double pixelsPerPoint(int band) const;
    void tilePixelSize(const TileKey& key, const Rect& pageFrame, int* width, int* height) const;
    bool makeJob(const TileSlot& slot, Job* job) const;
    void workerMain();
    TileImage render(PageRasterSource& source, const Job& job);
    void publish(TileImage image);
    void bumpGenerationLocked();

    void rebuildLayoutLocked();

    std::vector<PageGeometry> pages_;
    std::vector<int> geometrySlot_;
    Layout layout_;
    ViewSpec spec_{};
    int sheet_ = 0;
    mutable std::mutex cacheMutex_;
    mutable TileCache cache_;
    double scale_ = 1;
    double screenScale_ = 2;
    Rect visible_{};
    std::atomic<std::uint64_t> generation_{1};

    TileClient* client_ = nullptr;
    std::mutex clientMutex_;

    PageRasterSource* source_ = nullptr;
    std::mutex queueMutex_;
    std::condition_variable queueCV_;
    std::condition_variable idleCV_;
    std::deque<Job> jobs_;
    TileKeySet inflight_;
    int active_ = 0;
    bool stop_ = false;
    std::vector<std::thread> workers_;
};

}  // namespace pager
