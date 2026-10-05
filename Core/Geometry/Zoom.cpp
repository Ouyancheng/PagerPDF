#include "Zoom.hpp"

#include <algorithm>
#include <cmath>

namespace pager {

double ClampScale(double scale) {
    return std::clamp(scale, 0.25, 8.0);
}

int ScaleKeyForZoom(double scale) {
    return static_cast<int>(std::lround(ClampScale(scale) * 100.0));
}

double LayerContentsScale(double screenScale, double zoom) {
    const double screen = screenScale <= 0 ? 1 : screenScale;
    const double desired = std::max(0.05, ClampScale(zoom) * screen);
    // CATiledLayer drops the draw ("bogus layer size") if contentsScale makes the
    // document bitmap enormous. Cap here; levelsOfDetailBias covers deeper zooms.
    return std::min(desired, std::max(screen, 4.0));
}

EdgeInsets CenteringInsets(Size content, Size view) {
    EdgeInsets inset;
    const double extraX = std::max(0.0, (view.width - content.width) * 0.5);
    const double extraY = std::max(0.0, (view.height - content.height) * 0.5);
    inset.left = extraX;
    inset.right = extraX;
    inset.top = extraY;
    inset.bottom = extraY;
    return inset;
}

Point ClampedOffset(Point offset, Size content, Size view) {
    const EdgeInsets inset = CenteringInsets(content, view);
    const double minX = -inset.left;
    const double maxX = std::max(minX, content.width + inset.right - view.width);
    const double minY = -inset.top;
    const double maxY = std::max(minY, content.height + inset.bottom - view.height);
    offset.x = std::clamp(offset.x, minX, maxX);
    offset.y = std::clamp(offset.y, minY, maxY);
    return offset;
}

ZoomCommit CommitPinch(double oldScale, Size oldContent, Point offset, Size viewSize, Point startInView,
                       Point endInView, double factor) {
    ZoomCommit commit;
    commit.scale = ClampScale(oldScale * factor);
    if (oldScale <= 0 || oldContent.width <= 0 || oldContent.height <= 0) {
        commit.scale = ClampScale(factor);
        commit.contentSize = oldContent;
        commit.offset = ClampedOffset(offset, commit.contentSize, viewSize);
        return commit;
    }
    const Point documentPoint{offset.x + startInView.x, offset.y + startInView.y};
    const double ratio = commit.scale / oldScale;
    commit.contentSize = Size{oldContent.width * ratio, oldContent.height * ratio};
    commit.offset = Point{documentPoint.x * ratio - endInView.x, documentPoint.y * ratio - endInView.y};
    commit.offset = ClampedOffset(commit.offset, commit.contentSize, viewSize);
    return commit;
}

ZoomCommit CommitZoom(double oldScale, Size oldContent, Point offset, Size viewSize, Point anchorInView,
                      double factor) {
    return CommitPinch(oldScale, oldContent, offset, viewSize, anchorInView, anchorInView, factor);
}

}  // namespace pager
