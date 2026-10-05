#include "Layout.hpp"

#include <algorithm>

namespace pager {

void Layout::rebuild(const std::vector<PageGeometry>& pages, double scale) {
    scale_ = scale <= 0 ? 1 : scale;
    pages_.clear();
    double maxWidth = 0;
    for (const PageGeometry& page : pages) {
        const Size displayed = DisplayedSize(page);
        maxWidth = std::max(maxWidth, displayed.width * scale_);
    }
    double y = kMargin * scale_;
    const double gap = kPageGap * scale_;
    const double margin = kMargin * scale_;
    for (const PageGeometry& page : pages) {
        const Size displayed = DisplayedSize(page);
        const double width = displayed.width * scale_;
        const double height = displayed.height * scale_;
        const double x = margin + (maxWidth - width) * 0.5;
        pages_.push_back(PageFrame{page.index, Rect{x, y, width, height}});
        y += height + gap;
    }
    if (!pages_.empty()) {
        y -= gap;
    }
    y += margin;
    contentSize_ = Size{maxWidth + margin * 2, std::max(y, margin * 2)};
}

int Layout::pageAt(Point documentPoint) const {
    for (const PageFrame& frame : pages_) {
        if (frame.frame.contains(documentPoint)) {
            return frame.index;
        }
    }
    return -1;
}

Rect Layout::pageFrame(int index) const {
    for (const PageFrame& frame : pages_) {
        if (frame.index == index) {
            return frame.frame;
        }
    }
    return {};
}

Point Layout::documentToPageView(int index, Point documentPoint) const {
    const Rect frame = pageFrame(index);
    if (scale_ == 0) {
        return {};
    }
    return Point{(documentPoint.x - frame.x) / scale_, (documentPoint.y - frame.y) / scale_};
}

Point Layout::pageViewToDocument(int index, Point pageViewPoint) const {
    const Rect frame = pageFrame(index);
    return Point{frame.x + pageViewPoint.x * scale_, frame.y + pageViewPoint.y * scale_};
}

}  // namespace pager
