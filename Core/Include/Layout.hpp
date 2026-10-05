#pragma once

#include "Geometry.hpp"

#include <vector>

namespace pager {

struct PageFrame {
    int index = 0;
    Rect frame;
};

class Layout {
public:
    static constexpr double kPageGap = 12;
    static constexpr double kMargin = 16;

    void rebuild(const std::vector<PageGeometry>& pages, double scale);
    const std::vector<PageFrame>& pages() const { return pages_; }
    Size contentSize() const { return contentSize_; }
    double scale() const { return scale_; }

    int pageAt(Point documentPoint) const;
    // Pages whose frames intersect `rect`, in layout order.
    std::vector<int> pagesIntersecting(Rect rect) const;
    Rect pageFrame(int index) const;
    const PageFrame* frameFor(int index) const;
    Point documentToPageView(int index, Point documentPoint) const;
    Point pageViewToDocument(int index, Point pageViewPoint) const;

private:
    std::size_t firstAtOrBelow(double y) const;

    std::vector<PageFrame> pages_;
    // Page index -> position in pages_, or -1.
    std::vector<int> slotForIndex_;
    Size contentSize_{};
    double scale_ = 1;
};

}  // namespace pager
