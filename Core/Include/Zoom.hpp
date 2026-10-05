#pragma once

#include "Geometry.hpp"

namespace pager {

struct ZoomCommit {
    double scale = 1;
    Point offset;
    Size contentSize;
};

struct EdgeInsets {
    double top = 0;
    double left = 0;
    double bottom = 0;
    double right = 0;
};

double ClampScale(double scale);
// Hundredths of the clamped scale, used as the tile-cache identity so a 1.3x view
// never reuses rasters built for 1.0x.
int ScaleKeyForZoom(double scale);
// The zoom a scale key stands for. Tiles must be rasterized *and* placed with this value,
// never the raw zoom, or neighbouring tiles drift apart.
double ZoomForScaleKey(int key);
// Display density for CATiledLayer.contentsScale: zoom × screen, capped so a
// long document does not hit the "bogus layer size" limit. Deeper zooms use LOD.
double LayerContentsScale(double screenScale, double zoom);

// Extra scroll-view inset so a page smaller than the viewport sits in the middle
// the way Preview / PDF Expert do when you pinch out.
EdgeInsets CenteringInsets(Size content, Size view);
// Allows a negative offset (into the centering inset) when the content is smaller
// than the view; otherwise clamps to the usual [0, content - view] range.
Point ClampedOffset(Point offset, Size content, Size view);

ZoomCommit CommitZoom(double oldScale, Size oldContent, Point offset, Size viewSize, Point anchorInView,
                      double factor);
// Same as CommitZoom, but the document point under startInView lands under endInView
// so a pinch can follow a moving centroid the way Maps/Preview do.
ZoomCommit CommitPinch(double oldScale, Size oldContent, Point offset, Size viewSize, Point startInView,
                       Point endInView, double factor);

}  // namespace pager
