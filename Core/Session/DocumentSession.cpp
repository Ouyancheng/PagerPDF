#include "DocumentSession.hpp"

#include "AnnotationGeometry.hpp"

#include <algorithm>
#include <cmath>

namespace pager {
namespace {

Color DefaultColor(AnnotationKind kind) {
    switch (kind) {
        case AnnotationKind::Highlight:
            return Color{1, 0.84f, 0.12f, 0.42f};
        case AnnotationKind::Underline:
            return Color{0.1f, 0.35f, 0.9f, 1};
        case AnnotationKind::StrikeOut:
            return Color{0.85f, 0.15f, 0.15f, 1};
        case AnnotationKind::Square:
        case AnnotationKind::Circle:
        case AnnotationKind::Line:
            return Color{0.9f, 0.15f, 0.1f, 1};
        case AnnotationKind::FreeText:
            return Color{1, 0.95f, 0.4f, 0.95f};
        case AnnotationKind::Ink:
            return Color{0.05f, 0.05f, 0.05f, 1};
    }
    return Color{};
}

const Annotation* TopHit(const std::vector<Annotation>& notes, int pageIndex, const PageGeometry& page, Point pageView,
                         double slop) {
    for (auto note = notes.rbegin(); note != notes.rend(); ++note) {
        if (note->pageIndex == pageIndex && HitsAnnotation(*note, page, pageView, slop)) {
            return &*note;
        }
    }
    return nullptr;
}

Rect QuadBounds(const Quad& quad) {
    double minX = quad.v[0].x;
    double minY = quad.v[0].y;
    double maxX = quad.v[0].x;
    double maxY = quad.v[0].y;
    for (const Point& point : quad.v) {
        minX = std::min(minX, point.x);
        minY = std::min(minY, point.y);
        maxX = std::max(maxX, point.x);
        maxY = std::max(maxY, point.y);
    }
    return Rect{minX, minY, maxX - minX, maxY - minY};
}

}  // namespace

ToolStyle DefaultStyleForTool(Tool tool) {
    switch (tool) {
        case Tool::Highlight:
            return ToolStyle{Color{1, 0.84f, 0.12f, 0.42f}, 1, 14};
        case Tool::Underline:
            return ToolStyle{Color{0.1f, 0.35f, 0.9f, 1}, 1.5f, 14};
        case Tool::StrikeOut:
            return ToolStyle{Color{0.85f, 0.15f, 0.15f, 1}, 1.5f, 14};
        case Tool::Square:
        case Tool::Circle:
        case Tool::Line:
            return ToolStyle{Color{0.9f, 0.15f, 0.1f, 1}, 1.5f, 14};
        case Tool::FreeText:
            return ToolStyle{Color{0.12f, 0.12f, 0.14f, 1}, 1, 14};
        case Tool::Pen:
            return ToolStyle{Color{0.05f, 0.05f, 0.05f, 1}, 2.2f, 14};
        case Tool::Marker:
            return ToolStyle{Color{1, 0.85f, 0.1f, 0.45f}, 14, 14};
        default:
            return ToolStyle{Color{0.1f, 0.1f, 0.1f, 1}, 1.5f, 14};
    }
}

DocumentSession::DocumentSession() {
    const Tool tools[] = {Tool::Highlight, Tool::Underline, Tool::StrikeOut, Tool::Square, Tool::Circle,
                          Tool::Line,      Tool::FreeText,  Tool::Pen,       Tool::Marker, Tool::Eraser};
    for (const Tool tool : tools) {
        styles_[static_cast<int>(tool)] = DefaultStyleForTool(tool);
    }
}

void DocumentSession::setToolStyle(Tool tool, ToolStyle style) {
    const int index = static_cast<int>(tool);
    if (index < 0 || index >= 16) {
        return;
    }
    if (style.lineWidth <= 0) {
        style.lineWidth = DefaultStyleForTool(tool).lineWidth;
    }
    if (style.fontSize <= 0) {
        style.fontSize = 14;
    }
    styles_[index] = style;
}

ToolStyle DocumentSession::toolStyle(Tool tool) const {
    const int index = static_cast<int>(tool);
    if (index < 0 || index >= 16) {
        return DefaultStyleForTool(tool);
    }
    const ToolStyle& stored = styles_[index];
    if (stored.color.a == 0 && stored.lineWidth <= 0) {
        return DefaultStyleForTool(tool);
    }
    return stored;
}

const Annotation* DocumentSession::selectedAnnotation() const {
    return notes_.find(selectedNote_);
}

Annotation* DocumentSession::selectedAnnotationMutable() {
    return notes_.findMutable(selectedNote_);
}

void DocumentSession::setSearchHits(std::vector<TextSelection> hits) {
    searchHits_ = std::move(hits);
    searchIndex_ = searchHits_.empty() ? -1 : 0;
    ++searchRevision_;
}

const TextSelection* DocumentSession::currentSearchHit() const {
    if (searchIndex_ < 0 || searchIndex_ >= static_cast<int>(searchHits_.size())) {
        return nullptr;
    }
    return &searchHits_[static_cast<std::size_t>(searchIndex_)];
}

bool DocumentSession::advanceSearch(int delta) {
    if (searchHits_.empty()) {
        searchIndex_ = -1;
        return false;
    }
    const int count = static_cast<int>(searchHits_.size());
    searchIndex_ = (searchIndex_ + delta) % count;
    if (searchIndex_ < 0) {
        searchIndex_ += count;
    }
    ++searchRevision_;
    return true;
}

AnnotationId DocumentSession::addAnnotation(Annotation annotation) {
    return notes_.add(std::move(annotation));
}

AnnotationId DocumentSession::addMarkup(AnnotationKind kind, const TextSelection& selection, Color color,
                                        float lineWidth) {
    if (selection.quads.empty()) {
        return {};
    }
    Color resolved = color.a == 0 ? activeStyle().color : color;
    if (resolved.a == 0) {
        resolved = DefaultColor(kind);
    }
    // A selection that runs across a page break becomes one markup per page; a single
    // annotation can only live on one page.
    std::vector<int> pageOrder;
    for (const SelectionQuad& quad : selection.quads) {
        if (std::find(pageOrder.begin(), pageOrder.end(), quad.pageIndex) == pageOrder.end()) {
            pageOrder.push_back(quad.pageIndex);
        }
    }
    AnnotationId first;
    notes_.beginGroup();
    for (const int pageIndex : pageOrder) {
        Annotation annotation;
        annotation.kind = kind;
        annotation.pageIndex = pageIndex;
        annotation.color = resolved;
        annotation.lineWidth = lineWidth > 0 ? lineWidth : (activeStyle().lineWidth > 0 ? activeStyle().lineWidth : 1.5f);
        if (const PageGeometry* page = viewport_.geometry(pageIndex)) {
            annotation.stableKey = page->stableKey;
        }
        annotation.contents = selection.text;
        bool haveBounds = false;
        for (const SelectionQuad& quad : selection.quads) {
            if (quad.pageIndex != pageIndex) {
                continue;
            }
            annotation.quads.push_back(quad.quad);
            const Rect bounds = QuadBounds(quad.quad);
            annotation.bounds = haveBounds ? annotation.bounds.united(bounds) : bounds;
            haveBounds = true;
        }
        const AnnotationId id = notes_.add(std::move(annotation));
        if (first.value == 0) {
            first = id;
        }
    }
    notes_.endGroup();
    return first;
}

AnnotationId DocumentSession::addShape(AnnotationKind kind, int pageIndex, const PageGeometry& page, Point pageViewA,
                                       Point pageViewB, Color color, float lineWidth) {
    const Point userA = PageViewToUser(page, pageViewA);
    const Point userB = PageViewToUser(page, pageViewB);
    Annotation annotation;
    annotation.kind = kind;
    annotation.pageIndex = pageIndex;
    annotation.stableKey = page.stableKey;
    annotation.color = color.a == 0 ? activeStyle().color : color;
    if (annotation.color.a == 0) {
        annotation.color = DefaultColor(kind);
    }
    annotation.lineWidth = lineWidth <= 0 ? activeStyle().lineWidth : lineWidth;
    if (annotation.lineWidth <= 0) {
        annotation.lineWidth = 1.5f;
    }
    annotation.bounds = BoundsOfPoints(userA, userB);
    annotation.lineStart = userA;
    annotation.lineEnd = userB;
    if (annotation.bounds.width < 1) {
        annotation.bounds.width = 1;
    }
    if (annotation.bounds.height < 1) {
        annotation.bounds.height = 1;
    }
    return notes_.add(std::move(annotation));
}

AnnotationId DocumentSession::addTextNote(int pageIndex, const PageGeometry& page, Point pageView,
                                          const std::string& text, Color color, float fontSize) {
    const ToolStyle style = activeStyle();
    Annotation annotation;
    annotation.kind = AnnotationKind::FreeText;
    annotation.pageIndex = pageIndex;
    annotation.stableKey = page.stableKey;
    annotation.color = color.a == 0 ? style.color : color;
    if (annotation.color.a == 0) {
        annotation.color = DefaultColor(AnnotationKind::FreeText);
    }
    annotation.fontSize = fontSize > 0 ? fontSize : style.fontSize;
    if (annotation.fontSize <= 0) {
        annotation.fontSize = 14;
    }
    annotation.contents = text;
    const double width = std::max(120.0, static_cast<double>(annotation.fontSize) * 12.0);
    const double height = std::max(36.0, static_cast<double>(annotation.fontSize) * 3.2);
    // Build the box in page-view space (the tap is its top-left corner on screen) so it
    // extends right and down whatever the page rotation is.
    const Size displayed = DisplayedSize(page);
    const double left = std::clamp(pageView.x, 0.0, std::max(0.0, displayed.width - width));
    const double top = std::clamp(pageView.y, 0.0, std::max(0.0, displayed.height - height));
    const Point userA = PageViewToUser(page, Point{left, top});
    const Point userB = PageViewToUser(page, Point{left + width, top + height});
    annotation.bounds = BoundsOfPoints(userA, userB);
    return notes_.add(std::move(annotation));
}

AnnotationId DocumentSession::commitPen(int pageIndex, const PageGeometry& page, Color color, float baseWidth,
                                        bool pressure) {
    std::vector<InkSample> samples = pen_.finish();
    if (samples.empty()) {
        return {};
    }
    if (samples.size() == 1) {
        // A tap still deposits a dot, matching PDF Expert / PencilKit.
        InkSample extra = samples.front();
        extra.x += 0.02;
        samples.push_back(extra);
    }
    // Clip the stroke to the page so a pointer that crossed the page edge does not produce
    // ink at nonsense coordinates in the start page's user space.
    const double clipMinX = page.cropBox.x;
    const double clipMinY = page.cropBox.y;
    const double clipMaxX = page.cropBox.x + page.cropBox.width;
    const double clipMaxY = page.cropBox.y + page.cropBox.height;
    for (InkSample& sample : samples) {
        sample.x = std::clamp(sample.x, clipMinX, clipMaxX);
        sample.y = std::clamp(sample.y, clipMinY, clipMaxY);
    }
    Annotation annotation;
    annotation.kind = AnnotationKind::Ink;
    annotation.pageIndex = pageIndex;
    annotation.stableKey = page.stableKey;
    annotation.color = color;
    annotation.lineWidth = baseWidth;
    annotation.pressure = pressure;
    // Alpha lives in the color; keeping opacity at 1 avoids applying it twice on screen and
    // keeps flattened output consistent with what the user saw while drawing.
    annotation.opacity = 1;
    annotation.samples = std::move(samples);
    double minX = annotation.samples.front().x;
    double minY = annotation.samples.front().y;
    double maxX = minX;
    double maxY = minY;
    for (const InkSample& sample : annotation.samples) {
        minX = std::min(minX, sample.x);
        minY = std::min(minY, sample.y);
        maxX = std::max(maxX, sample.x);
        maxY = std::max(maxY, sample.y);
    }
    annotation.bounds = Rect{minX, minY, std::max(1.0, maxX - minX), std::max(1.0, maxY - minY)};
    return notes_.add(std::move(annotation));
}

void DocumentSession::setShapeDraft(AnnotationKind kind, int pageIndex, Point start, Point current) {
    shapeDraft_.active = true;
    shapeDraft_.kind = kind;
    shapeDraft_.pageIndex = pageIndex;
    shapeDraft_.start = start;
    shapeDraft_.current = current;
    const ToolStyle style = activeStyle();
    shapeDraft_.color = style.color.a == 0 ? DefaultColor(kind) : style.color;
    shapeDraft_.lineWidth = style.lineWidth > 0 ? style.lineWidth : 1.5f;
}

void DocumentSession::clearShapeDraft() {
    shapeDraft_ = {};
}

bool DocumentSession::selectNoteAt(Point documentPoint) {
    selectedNote_ = {};
    const int pageIndex = viewport_.layout().pageAt(documentPoint);
    const PageGeometry* page = pageIndex < 0 ? nullptr : viewport_.geometry(pageIndex);
    if (page == nullptr) {
        return false;
    }
    const Point pageView = viewport_.layout().documentToPageView(pageIndex, documentPoint);
    const Annotation* hit = TopHit(notes_.annotations(), pageIndex, *page, pageView, 8);
    if (hit == nullptr) {
        return false;
    }
    selectedNote_ = hit->id;
    return true;
}

bool DocumentSession::deleteSelectedNote() {
    if (selectedNote_.value == 0) {
        return false;
    }
    const bool removed = notes_.remove(selectedNote_);
    selectedNote_ = {};
    return removed;
}

void DocumentSession::sanitizeSelection() {
    if (selectedNote_.value != 0 && notes_.find(selectedNote_) == nullptr) {
        selectedNote_ = {};
    }
}

void DocumentSession::eraseAt(int pageIndex, const PageGeometry& page, Point pageView, double radius) {
    eraseAlong(pageIndex, page, pageView, pageView, radius);
}

bool DocumentSession::eraseAlong(int pageIndex, const PageGeometry& page, Point from, Point to, double radius) {
    const std::uint64_t before = notes_.revision();
    notes_.beginGroup();
    std::vector<AnnotationId> shapes;
    for (const Annotation& note : notes_.annotations()) {
        if (note.pageIndex == pageIndex && note.kind != AnnotationKind::Ink &&
            HitsAnnotationAlong(note, page, from, to, radius)) {
            shapes.push_back(note.id);
        }
    }
    for (const AnnotationId id : shapes) {
        notes_.remove(id);
    }
    notes_.eraseAlong(pageIndex, page, from, to, radius);
    notes_.endGroup();
    sanitizeSelection();
    return notes_.revision() != before;
}

}  // namespace pager
