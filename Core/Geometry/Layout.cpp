#include "Layout.hpp"

#include <algorithm>
#include <cmath>

namespace pager {
namespace {

int ClampedSheet(int sheet, int pageCount, const ViewSpec& spec) {
    const int count = SheetCount(pageCount, spec);
    if (count <= 0) {
        return 0;
    }
    return std::clamp(sheet, 0, count - 1);
}

}  // namespace

int SheetCount(int pageCount, ViewSpec spec) {
    spec = spec.normalized();
    if (pageCount <= 0) {
        return 0;
    }
    if (spec.isContinuous()) {
        return 1;
    }
    const int per = spec.pagesPerSheet();
    if (!spec.usesCoverSheet()) {
        return (pageCount + per - 1) / per;
    }
    if (pageCount == 1) {
        return 1;
    }
    return 1 + (pageCount - 1 + per - 1) / per;
}

int FirstPageOfSheet(int sheet, int pageCount, ViewSpec spec) {
    spec = spec.normalized();
    sheet = ClampedSheet(sheet, pageCount, spec);
    const int per = spec.pagesPerSheet();
    if (!spec.usesCoverSheet()) {
        return sheet * per;
    }
    if (sheet <= 0) {
        return 0;
    }
    return 1 + (sheet - 1) * per;
}

int PagesOnSheet(int sheet, int pageCount, ViewSpec spec) {
    spec = spec.normalized();
    if (pageCount <= 0) {
        return 0;
    }
    const int first = FirstPageOfSheet(sheet, pageCount, spec);
    const int next = FirstPageOfSheet(sheet + 1, pageCount, spec);
    const int end = sheet + 1 >= SheetCount(pageCount, spec) ? pageCount : next;
    return std::max(0, end - first);
}

int SheetForPage(int pageIndex, int pageCount, ViewSpec spec) {
    spec = spec.normalized();
    if (pageCount <= 0) {
        return 0;
    }
    pageIndex = std::clamp(pageIndex, 0, pageCount - 1);
    if (spec.isContinuous()) {
        return 0;
    }
    const int per = spec.pagesPerSheet();
    if (!spec.usesCoverSheet()) {
        return pageIndex / per;
    }
    if (pageIndex == 0) {
        return 0;
    }
    return 1 + (pageIndex - 1) / per;
}

void Layout::recordFrame(int index, Rect frame) {
    if (index >= 0) {
        if (static_cast<std::size_t>(index) >= slotForIndex_.size()) {
            slotForIndex_.resize(static_cast<std::size_t>(index) + 1, -1);
        }
        slotForIndex_[static_cast<std::size_t>(index)] = static_cast<int>(pages_.size());
    }
    pages_.push_back(PageFrame{index, frame});
}

const PageGeometry* Layout::geometryWithIndex(const std::vector<PageGeometry>& pages, int index) const {
    if (index < 0) {
        return nullptr;
    }
    if (static_cast<std::size_t>(index) < pages.size() && pages[static_cast<std::size_t>(index)].index == index) {
        return &pages[static_cast<std::size_t>(index)];
    }
    for (const PageGeometry& page : pages) {
        if (page.index == index) {
            return &page;
        }
    }
    return nullptr;
}

void Layout::rebuild(const std::vector<PageGeometry>& pages, double scale) {
    rebuild(pages, ViewSpec{}, 0, scale);
}

void Layout::rebuild(const std::vector<PageGeometry>& pages, const ViewSpec& spec, int sheet, double scale) {
    scale_ = scale <= 0 ? 1 : scale;
    spec_ = spec.normalized();
    const int pageCount = static_cast<int>(pages.size());
    sheet_ = ClampedSheet(sheet, pageCount, spec_);
    pages_.clear();
    slotForIndex_.clear();

    const double gap = kPageGap * scale_;
    const double margin = kMargin * scale_;
    if (pages.empty()) {
        contentSize_ = Size{margin * 2, margin * 2};
        return;
    }

    std::vector<const PageGeometry*> cells;
    if (spec_.isPaged()) {
        const int first = FirstPageOfSheet(sheet_, pageCount, spec_);
        const int count = PagesOnSheet(sheet_, pageCount, spec_);
        for (int i = 0; i < count; ++i) {
            cells.push_back(geometryWithIndex(pages, first + i));
        }
    } else if (spec_.usesCoverSheet()) {
        cells.push_back(geometryWithIndex(pages, pages.front().index));
        const int cols = std::max(1, spec_.columns);
        for (int column = 1; column < cols; ++column) {
            cells.push_back(nullptr);
        }
        for (std::size_t index = 1; index < pages.size(); ++index) {
            cells.push_back(&pages[index]);
        }
    } else {
        cells.reserve(pages.size());
        for (const PageGeometry& page : pages) {
            cells.push_back(&page);
        }
    }

    int cols = 1;
    int rows = 1;
    if (spec_.isPaged()) {
        cols = std::max(1, spec_.columns);
        rows = std::max(1, spec_.rows);
    } else if (spec_.continuousY()) {
        cols = std::max(1, spec_.columns);
        rows = static_cast<int>((cells.size() + static_cast<std::size_t>(cols) - 1) / static_cast<std::size_t>(cols));
    } else {
        rows = std::max(1, spec_.rows);
        cols = static_cast<int>((cells.size() + static_cast<std::size_t>(rows) - 1) / static_cast<std::size_t>(rows));
    }
    cols = std::max(1, cols);
    rows = std::max(1, rows);

    std::vector<double> colW(static_cast<std::size_t>(cols), 0);
    std::vector<double> rowH(static_cast<std::size_t>(rows), 0);
    for (std::size_t index = 0; index < cells.size(); ++index) {
        const int row = static_cast<int>(index) / cols;
        const int column = static_cast<int>(index) % cols;
        if (row >= rows || cells[index] == nullptr) {
            continue;
        }
        const Size displayed = DisplayedSize(*cells[index]);
        colW[static_cast<std::size_t>(column)] = std::max(colW[static_cast<std::size_t>(column)], displayed.width * scale_);
        rowH[static_cast<std::size_t>(row)] = std::max(rowH[static_cast<std::size_t>(row)], displayed.height * scale_);
    }

    std::vector<double> colX(static_cast<std::size_t>(cols), margin);
    std::vector<double> rowY(static_cast<std::size_t>(rows), margin);
    double x = margin;
    for (int column = 0; column < cols; ++column) {
        colX[static_cast<std::size_t>(column)] = x;
        x += colW[static_cast<std::size_t>(column)] + gap;
    }
    if (cols > 0) {
        x -= gap;
    }
    x += margin;
    double y = margin;
    for (int row = 0; row < rows; ++row) {
        rowY[static_cast<std::size_t>(row)] = y;
        y += rowH[static_cast<std::size_t>(row)] + gap;
    }
    if (rows > 0) {
        y -= gap;
    }
    y += margin;

    for (std::size_t index = 0; index < cells.size(); ++index) {
        if (cells[index] == nullptr) {
            continue;
        }
        const int row = static_cast<int>(index) / cols;
        const int column = static_cast<int>(index) % cols;
        if (row >= rows) {
            continue;
        }
        const Size displayed = DisplayedSize(*cells[index]);
        const double width = displayed.width * scale_;
        const double height = displayed.height * scale_;
        const double px = colX[static_cast<std::size_t>(column)] + (colW[static_cast<std::size_t>(column)] - width) * 0.5;
        const double py = rowY[static_cast<std::size_t>(row)] + (rowH[static_cast<std::size_t>(row)] - height) * 0.5;
        recordFrame(cells[index]->index, Rect{px, py, width, height});
    }

    contentSize_ = Size{std::max(x, margin * 2), std::max(y, margin * 2)};
}

int Layout::pageAt(Point documentPoint) const {
    for (const PageFrame& frame : pages_) {
        if (frame.frame.contains(documentPoint)) {
            return frame.index;
        }
    }
    return -1;
}

std::vector<int> Layout::pagesIntersecting(Rect rect) const {
    std::vector<int> result;
    if (rect.width <= 0 || rect.height <= 0) {
        return result;
    }
    for (const PageFrame& frame : pages_) {
        if (frame.frame.intersects(rect)) {
            result.push_back(frame.index);
        }
    }
    return result;
}

const PageFrame* Layout::frameFor(int index) const {
    if (index < 0 || static_cast<std::size_t>(index) >= slotForIndex_.size()) {
        return nullptr;
    }
    const int slot = slotForIndex_[static_cast<std::size_t>(index)];
    return slot < 0 ? nullptr : &pages_[static_cast<std::size_t>(slot)];
}

Rect Layout::pageFrame(int index) const {
    const PageFrame* frame = frameFor(index);
    return frame == nullptr ? Rect{} : frame->frame;
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
