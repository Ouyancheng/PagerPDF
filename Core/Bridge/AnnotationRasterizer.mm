#include "AnnotationRasterizer.h"

#include "AnnotationGeometry.hpp"
#include "OverlayRenderer.h"

#include <CoreGraphics/CoreGraphics.h>

namespace pager {

bool PageAnnotations::touches(const Rect& pageViewRect) const {
    for (const Rect& bounds : paintBounds) {
        if (bounds.intersects(pageViewRect)) {
            return true;
        }
    }
    return false;
}

PageAnnotationsRef MakePageAnnotations(int pageIndex, const PageGeometry& page, std::uint64_t revision,
                                       std::vector<Annotation> notes, AnnotationId hideContents) {
    auto snapshot = std::make_shared<PageAnnotations>();
    snapshot->pageIndex = pageIndex;
    snapshot->page = page;
    snapshot->revision = revision;
    snapshot->hideContents = hideContents;
    snapshot->paintBounds.reserve(notes.size());
    for (const Annotation& note : notes) {
        snapshot->paintBounds.push_back(PageViewPaintBounds(page, note));
    }
    snapshot->notes = std::move(notes);
    return snapshot;
}

AnnotationRasterizer::AnnotationRasterizer() : worker_([this]() { workerMain(); }) {}

AnnotationRasterizer::~AnnotationRasterizer() { stop(); }

void AnnotationRasterizer::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop_ = true;
        jobs_.clear();
    }
    cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
    std::lock_guard<std::mutex> lock(callbackMutex_);
    callback_ = nullptr;
}

void AnnotationRasterizer::setCallback(Callback callback) {
    std::lock_guard<std::mutex> lock(callbackMutex_);
    callback_ = std::move(callback);
}

void AnnotationRasterizer::submit(std::vector<AnnotationTileJob> jobs) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_) {
            return;
        }
        jobs_.assign(std::make_move_iterator(jobs.begin()), std::make_move_iterator(jobs.end()));
    }
    cv_.notify_all();
}

void AnnotationRasterizer::cancelAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    jobs_.clear();
}

void AnnotationRasterizer::workerMain() {
    InkPathCache cache;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    const CGBitmapInfo info = static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) |
                              static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little);
    for (;;) {
        AnnotationTileJob job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [&]() { return stop_ || !jobs_.empty(); });
            if (stop_) {
                break;
            }
            job = std::move(jobs_.front());
            jobs_.pop_front();
        }
        AnnotationTile tile;
        tile.key = job.key;
        tile.epoch = job.epoch;
        tile.revision = job.snapshot ? job.snapshot->revision : 0;
        if (job.snapshot && job.pixelWidth > 0 && job.pixelHeight > 0 && job.snapshot->touches(job.pageRect)) {
            CGContextRef context = CGBitmapContextCreate(nullptr, static_cast<size_t>(job.pixelWidth),
                                                         static_cast<size_t>(job.pixelHeight), 8, 0, space, info);
            if (context != nullptr) {
                CGContextClearRect(context, CGRectMake(0, 0, job.pixelWidth, job.pixelHeight));
                CGContextTranslateCTM(context, 0, job.pixelHeight);
                CGContextScaleCTM(context, 1, -1);
                CGContextScaleCTM(context, job.pixelsPerPoint, job.pixelsPerPoint);
                CGContextTranslateCTM(context, -job.pageRect.x, -job.pageRect.y);
                const PageAnnotations& snapshot = *job.snapshot;
                for (std::size_t index = 0; index < snapshot.notes.size(); ++index) {
                    if (snapshot.paintBounds[index].intersects(job.pageRect)) {
                        DrawAnnotationInPage(context, snapshot.page, snapshot.notes[index], snapshot.hideContents,
                                             &cache);
                    }
                }
                tile.image = ImageHandle(CGBitmapContextCreateImage(context));
                CGContextRelease(context);
            }
        }
        Callback callback;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            callback = callback_;
        }
        if (callback) {
            callback(std::move(tile));
        }
    }
    CGColorSpaceRelease(space);
}

}  // namespace pager
