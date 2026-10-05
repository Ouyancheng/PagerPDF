#pragma once

#include "DocumentSession.hpp"

#include <CoreGraphics/CGContext.h>
#include <CoreGraphics/CGImage.h>

#include <functional>
#include <vector>

namespace pager {

struct PageTileBlit {
    CGRect pageClip = {};
    CGRect frame = {};
    CGImageRef image = nullptr;
};

using TileImageLookup = std::function<CGImageRef(const TileKey&)>;
using TileFallbackWalk =
    std::function<void(const std::function<void(int pageIndex, CGRect frame, CGImageRef image)>& emit)>;

// Desk color behind the pages. Every surface that shows through (scroll view,
// tiled layer, DrawPages fill) must use this exact gray or a zoom looks like a flash.
constexpr double kCanvasGray = 0.91;

inline void FillCanvasColor(CGContextRef context) {
    CGContextSetRGBFillColor(context, kCanvasGray, kCanvasGray, kCanvasGray, 1);
}

void DrawDocument(CGContextRef context, CGRect dirty, const DocumentSession& session, const TileImageLookup& images,
                  bool drawLivePen = true, const TileFallbackWalk& fallbacks = nullptr);
void DrawPages(CGContextRef context, CGRect dirty, const DocumentSession& session, const TileImageLookup& images,
               const TileFallbackWalk& fallbacks = nullptr);
// Snapshot draw for CATiledLayer: that layer paints on a worker thread, so the
// caller must retain every image for the duration of this call.
void DrawPageLayer(CGContextRef context, CGRect dirty, const std::vector<CGRect>& pages,
                   const std::vector<PageTileBlit>& tiles);
void DrawSessionOverlay(CGContextRef context, CGRect dirty, const DocumentSession& session, bool drawLivePen = true,
                        AnnotationId hideContents = {});
void DrawLivePen(CGContextRef context, const DocumentSession& session);

}
