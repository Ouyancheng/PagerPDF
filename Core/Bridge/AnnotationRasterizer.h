#pragma once

#include "Annotation.hpp"
#include "TileCache.hpp"

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace pager {

// Immutable copy of one page's annotations, shared by every tile job for that revision.
struct PageAnnotations {
    int pageIndex = -1;
    PageGeometry page;
    std::uint64_t revision = 0;
    std::vector<Annotation> notes;
    // Page-view paint bounds, parallel to `notes`.
    std::vector<Rect> paintBounds;
    // FreeText whose text is being edited in place: draw the box, not the words.
    AnnotationId hideContents;

    bool touches(const Rect& pageViewRect) const;
};
using PageAnnotationsRef = std::shared_ptr<const PageAnnotations>;

PageAnnotationsRef MakePageAnnotations(int pageIndex, const PageGeometry& page, std::uint64_t revision,
                                       std::vector<Annotation> notes, AnnotationId hideContents);

struct AnnotationTileJob {
    TileKey key;
    PageAnnotationsRef snapshot;
    // Tile rect in page-view points.
    Rect pageRect;
    double pixelsPerPoint = 1;
    int pixelWidth = 0;
    int pixelHeight = 0;
    std::uint64_t epoch = 0;
};

struct AnnotationTile {
    TileKey key;
    std::uint64_t revision = 0;
    std::uint64_t epoch = 0;
    // Null when nothing on the tile is painted.
    ImageHandle image;
};

// Renders transparent annotation tiles on its own thread so committed notes cost the main
// thread nothing while scrolling, and edits never wait behind slow PDF page rasters.
class AnnotationRasterizer {
public:
    using Callback = std::function<void(AnnotationTile)>;

    AnnotationRasterizer();
    ~AnnotationRasterizer();
    AnnotationRasterizer(const AnnotationRasterizer&) = delete;
    AnnotationRasterizer& operator=(const AnnotationRasterizer&) = delete;

    // Called on the render thread.
    void setCallback(Callback callback);
    // Replaces the queue. Jobs are rendered in the given order.
    void submit(std::vector<AnnotationTileJob> jobs);
    void cancelAll();
    void stop();

private:
    void workerMain();

    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<AnnotationTileJob> jobs_;
    bool stop_ = false;
    std::mutex callbackMutex_;
    Callback callback_;
    std::thread worker_;
};

}  // namespace pager
