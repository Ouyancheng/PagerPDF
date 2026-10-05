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
    Rect pageFrame(int index) const;
    Point documentToPageView(int index, Point documentPoint) const;
    Point pageViewToDocument(int index, Point pageViewPoint) const;

private:
    std::vector<PageFrame> pages_;
    Size contentSize_{};
    double scale_ = 1;
};

}  // namespace pager
