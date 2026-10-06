#pragma once

#include "Geometry.hpp"

#include <algorithm>
#include <vector>

namespace pager {

struct PageFrame {
    int index = 0;
    Rect frame;
};

// columns/rows: a positive count, or kContinuous on that axis.
// Default {1, kContinuous} is the current one-column vertical strip.
struct ViewSpec {
    static constexpr int kContinuous = 0;
    static constexpr int kAutoColumns = 4;

    int columns = 1;
    int rows = kContinuous;
    bool coverAlone = false;

    bool continuousX() const { return columns <= kContinuous; }
    bool continuousY() const { return rows <= kContinuous; }
    bool isContinuous() const { return continuousX() || continuousY(); }
    bool isPaged() const { return !isContinuous(); }
    // A horizontal strip should fill the viewport height; other modes fill the width.
    bool prefersFitHeight() const {
        const ViewSpec spec = normalized();
        return spec.continuousX() && !spec.continuousY();
    }

    ViewSpec normalized() const {
        ViewSpec spec = *this;
        if (spec.columns < kContinuous) {
            spec.columns = kContinuous;
        }
        if (spec.rows < kContinuous) {
            spec.rows = kContinuous;
        }
        if (spec.continuousX() && spec.continuousY()) {
            spec.columns = kAutoColumns;
            spec.rows = kContinuous;
        }
        return spec;
    }

    int pagesPerSheet() const {
        const ViewSpec spec = normalized();
        return std::max(1, spec.columns) * std::max(1, spec.rows);
    }

    bool usesCoverSheet() const {
        const ViewSpec spec = normalized();
        return spec.coverAlone && spec.columns >= 2;
    }

    bool operator==(const ViewSpec& other) const {
        const ViewSpec a = normalized();
        const ViewSpec b = other.normalized();
        return a.columns == b.columns && a.rows == b.rows && a.coverAlone == b.coverAlone;
    }

    bool operator!=(const ViewSpec& other) const { return !(*this == other); }
};

int SheetCount(int pageCount, ViewSpec spec);
int SheetForPage(int pageIndex, int pageCount, ViewSpec spec);
int FirstPageOfSheet(int sheet, int pageCount, ViewSpec spec);
int PagesOnSheet(int sheet, int pageCount, ViewSpec spec);

class Layout {
public:
    static constexpr double kPageGap = 12;
    static constexpr double kMargin = 16;

    void rebuild(const std::vector<PageGeometry>& pages, double scale);
    void rebuild(const std::vector<PageGeometry>& pages, const ViewSpec& spec, int sheet, double scale);
    const std::vector<PageFrame>& pages() const { return pages_; }
    Size contentSize() const { return contentSize_; }
    double scale() const { return scale_; }
    const ViewSpec& spec() const { return spec_; }
    int sheet() const { return sheet_; }

    int pageAt(Point documentPoint) const;
    // Pages whose frames intersect `rect`, in layout order.
    std::vector<int> pagesIntersecting(Rect rect) const;
    Rect pageFrame(int index) const;
    const PageFrame* frameFor(int index) const;
    Point documentToPageView(int index, Point documentPoint) const;
    Point pageViewToDocument(int index, Point pageViewPoint) const;

private:
    void recordFrame(int index, Rect frame);
    const PageGeometry* geometryWithIndex(const std::vector<PageGeometry>& pages, int index) const;

    std::vector<PageFrame> pages_;
    // Page index -> position in pages_, or -1.
    std::vector<int> slotForIndex_;
    Size contentSize_{};
    double scale_ = 1;
    ViewSpec spec_{};
    int sheet_ = 0;
};

}  // namespace pager
