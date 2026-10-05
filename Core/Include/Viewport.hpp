#pragma once

#include "Layout.hpp"
#include "PageRasterSource.hpp"
#include "TileCache.hpp"

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

namespace pager {

struct TileSlot {
    TileKey key;
    Rect documentFrame;
    bool ready = false;
};

class TileClient {
public:
    virtual ~TileClient() = default;
    virtual void tileReady(TileImage image) = 0;
};

class Viewport {
public:
    static constexpr int kTilePixels = 512;

    explicit Viewport(std::size_t cacheBytes = 128ull * 1024ull * 1024ull);
    ~Viewport();

    Viewport(const Viewport&) = delete;
    Viewport& operator=(const Viewport&) = delete;

    void setPages(std::vector<PageGeometry> pages);
    // Raster / pinch zoom. Does not rebuild page frames — those stay in PDF points
    // so the canvas size is stable and UIScrollView can zoom without a flash.
    void setScale(double scale);
    void setScreenScale(double screenScale);
    void setVisibleRect(Rect visible);
    void setClient(TileClient* client);

    const Layout& layout() const { return layout_; }
    double scale() const { return scale_; }
    double screenScale() const { return screenScale_; }
    const std::vector<PageGeometry>& pages() const { return pages_; }
    const PageGeometry* geometry(int index) const;

    std::vector<TileSlot> visibleSlots() const;
    // Document-space rect for a tile key. Valid for any cached band; layout is
    // always PDF points, so an old zoom's rasters still sit on the same page.
    Rect tileDocumentFrame(const TileKey& key) const;
    void requestVisibleTiles(PageRasterSource& source);
    bool copyTile(const TileKey& key, TileImage* image) const;
    // Drops every cached and queued tile (e.g. after the screen scale changed).
    void invalidateTiles();

private:
    struct Job {
        TileKey key;
        double pageWidth = 0;
        double pageHeight = 0;
        double pixelsPerPoint = 1;
    };

    void workerMain();
    void enqueue(Job job);
    TileImage render(PageRasterSource& source, const Job& job);
    void publish(TileImage image);

    std::vector<PageGeometry> pages_;
    Layout layout_;
    mutable std::mutex cacheMutex_;
    TileCache cache_;
    double scale_ = 1;
    double screenScale_ = 2;
    Rect visible_{};

    TileClient* client_ = nullptr;
    std::mutex clientMutex_;

    PageRasterSource* source_ = nullptr;
    std::mutex queueMutex_;
    std::condition_variable queueCV_;
    std::deque<Job> jobs_;
    bool stop_ = false;
    std::thread worker_;
};

}  // namespace pager
