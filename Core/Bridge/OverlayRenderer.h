#pragma once

#include "DocumentSession.hpp"
#include "Ink.hpp"

#include <CoreGraphics/CGContext.h>
#include <CoreGraphics/CGImage.h>
#include <CoreGraphics/CGPath.h>

#include <unordered_map>
#include <vector>

namespace pager {

struct PageTileBlit {
    CGRect pageClip = {};
    CGRect frame = {};
    CGImageRef image = nullptr;
};

// Desk color behind the pages. Every surface that shows through (scroll view, page host,
// tile layers) must use this exact gray or a zoom looks like a flash.
constexpr double kCanvasGray = 0.91;

inline void FillCanvasColor(CGContextRef context) {
    CGContextSetRGBFillColor(context, kCanvasGray, kCanvasGray, kCanvasGray, 1);
}

// Caches the filled outline of ink strokes so a stroke that spans many tiles is built once.
// Not thread-safe: give each rendering thread its own cache.
class InkPathCache {
public:
    InkPathCache() = default;
    InkPathCache(const InkPathCache&) = delete;
    InkPathCache& operator=(const InkPathCache&) = delete;
    ~InkPathCache();
    // Borrowed reference, valid until the next call.
    CGPathRef pathFor(const PageGeometry& page, const Annotation& note);
    void clear();

private:
    struct Entry {
        std::uint64_t fingerprint = 0;
        CGPathRef path = nullptr;
    };
    std::unordered_map<std::uint64_t, Entry> entries_;
};

// +1 path that fills the union of `triangles` (they must share a winding, see BuildRibbon).
CGPathRef CreateRibbonPath(const std::vector<Triangle>& triangles);
RibbonOptions RibbonOptionsFor(const Annotation& note);

// Page space: the CTM maps page-view points (origin at the page's top-left, y down).
void DrawAnnotationInPage(CGContextRef context, const PageGeometry& page, const Annotation& note,
                          AnnotationId hideContents = {}, InkPathCache* cache = nullptr);
void DrawInkSamplesInPage(CGContextRef context, const PageGeometry& page, const std::vector<InkSample>& samples,
                          Color color, float lineWidth, bool pressure, RibbonOptions options = {});
// Pen colour/width/pressure the live stroke uses, so the committed note matches it exactly.
Annotation LiveStrokeStyle(const DocumentSession& session);

// Document space (layout coordinates).
void DrawPageLayer(CGContextRef context, CGRect dirty, const std::vector<CGRect>& pages,
                   const std::vector<PageTileBlit>& tiles);
void DrawAnnotationInDocument(CGContextRef context, const DocumentSession& session, const Annotation& note,
                              AnnotationId hideContents = {});
void DrawLivePen(CGContextRef context, const DocumentSession& session);
void DrawShapeDraft(CGContextRef context, const DocumentSession& session);
// Everything that sits above the page rasters (Mac draws it straight into its view).
void DrawSessionOverlay(CGContextRef context, CGRect dirty, const DocumentSession& session, bool drawLivePen = true,
                        AnnotationId hideContents = {});

}  // namespace pager
