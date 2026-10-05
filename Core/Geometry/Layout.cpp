#include "Layout.hpp"

#include <algorithm>

namespace pager {

void Layout::rebuild(const std::vector<PageGeometry>& pages, double scale) {
    scale_ = scale <= 0 ? 1 : scale;
    pages_.clear();
    slotForIndex_.clear();
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
        if (page.index >= 0) {
            if (static_cast<std::size_t>(page.index) >= slotForIndex_.size()) {
                slotForIndex_.resize(static_cast<std::size_t>(page.index) + 1, -1);
            }
            slotForIndex_[static_cast<std::size_t>(page.index)] = static_cast<int>(pages_.size());
        }
        pages_.push_back(PageFrame{page.index, Rect{x, y, width, height}});
        y += height + gap;
    }
    if (!pages_.empty()) {
        y -= gap;
    }
    y += margin;
    contentSize_ = Size{maxWidth + margin * 2, std::max(y, margin * 2)};
}

std::size_t Layout::firstAtOrBelow(double y) const {
    // Pages are stacked top to bottom, so frame bottoms are sorted.
    const auto it = std::lower_bound(pages_.begin(), pages_.end(), y, [](const PageFrame& frame, double value) {
        return frame.frame.y + frame.frame.height < value;
    });
    return static_cast<std::size_t>(it - pages_.begin());
}

int Layout::pageAt(Point documentPoint) const {
    for (std::size_t slot = firstAtOrBelow(documentPoint.y); slot < pages_.size(); ++slot) {
        const PageFrame& frame = pages_[slot];
        if (frame.frame.y > documentPoint.y) {
            break;
        }
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
    for (std::size_t slot = firstAtOrBelow(rect.y); slot < pages_.size(); ++slot) {
        const PageFrame& frame = pages_[slot];
        if (frame.frame.y >= rect.y + rect.height) {
            break;
        }
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
