#include "DocumentSession.hpp"

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

double Distance(Point a, Point b) {
    const double dx = a.x - b.x;
    const double dy = a.y - b.y;
    return std::sqrt(dx * dx + dy * dy);
}

double DistanceToSegment(Point point, Point start, Point end) {
    const double dx = end.x - start.x;
    const double dy = end.y - start.y;
    const double lengthSquared = dx * dx + dy * dy;
    double t = 0;
    if (lengthSquared > 0) {
        t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared;
        t = std::clamp(t, 0.0, 1.0);
    }
    return Distance(point, Point{start.x + t * dx, start.y + t * dy});
}

bool PointInQuad(Point point, const Quad& quad) {
    bool inside = false;
    for (int index = 0, previous = 3; index < 4; previous = index++) {
        const Point a = quad.v[index];
        const Point b = quad.v[previous];
        const bool crosses = (a.y > point.y) != (b.y > point.y);
        if (crosses && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) {
            inside = !inside;
        }
    }
    return inside;
}

bool HitsNote(const Annotation& note, const PageGeometry& page, Point pageView, double slop) {
    if (note.kind == AnnotationKind::Line) {
        return DistanceToSegment(pageView, UserToPageView(page, note.lineStart), UserToPageView(page, note.lineEnd)) <= slop;
    }
    if (note.kind == AnnotationKind::Ink) {
        for (const InkSample& sample : note.samples) {
            if (Distance(pageView, UserToPageView(page, Point{sample.x, sample.y})) <= slop) {
                return true;
            }
        }
        return false;
    }
    if (!note.quads.empty() && (note.kind == AnnotationKind::Highlight || note.kind == AnnotationKind::Underline ||
                                note.kind == AnnotationKind::StrikeOut)) {
        const Point user = PageViewToUser(page, pageView);
        for (const Quad& quad : note.quads) {
            if (PointInQuad(user, quad)) {
                return true;
            }
        }
        return false;
    }
    const Point min = UserToPageView(page, Point{note.bounds.x, note.bounds.y});
    const Point max = UserToPageView(page, Point{note.bounds.x + note.bounds.width, note.bounds.y + note.bounds.height});
    Rect bounds = BoundsOfPoints(min, max);
    bounds.x -= slop;
    bounds.y -= slop;
    bounds.width += slop * 2;
    bounds.height += slop * 2;
    if (note.kind == AnnotationKind::Circle) {
        const Point center = bounds.center();
        const double radiusX = std::max(1.0, bounds.width * 0.5);
        const double radiusY = std::max(1.0, bounds.height * 0.5);
        const double nx = (pageView.x - center.x) / radiusX;
        const double ny = (pageView.y - center.y) / radiusY;
        return nx * nx + ny * ny <= 1;
    }
    return bounds.contains(pageView);
}

const Annotation* TopHit(const std::vector<Annotation>& notes, int pageIndex, const PageGeometry& page, Point pageView,
                         double slop) {
    for (auto note = notes.rbegin(); note != notes.rend(); ++note) {
        if (note->pageIndex == pageIndex && HitsNote(*note, page, pageView, slop)) {
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
    return true;
}

AnnotationId DocumentSession::addAnnotation(Annotation annotation) {
    return notes_.add(std::move(annotation));
}

AnnotationId DocumentSession::addMarkup(AnnotationKind kind, const TextSelection& selection, Color color) {
    if (selection.quads.empty()) {
        return {};
    }
    Annotation annotation;
    annotation.kind = kind;
    annotation.pageIndex = selection.quads.front().pageIndex;
    annotation.color = color.a == 0 ? activeStyle().color : color;
    annotation.quads = {};
    annotation.bounds = QuadBounds(selection.quads.front().quad);
    annotation.contents = selection.text;
    for (const SelectionQuad& quad : selection.quads) {
        if (quad.pageIndex != annotation.pageIndex) {
            continue;
        }
        annotation.quads.push_back(quad.quad);
        const Rect bounds = QuadBounds(quad.quad);
        const double maxX = std::max(annotation.bounds.x + annotation.bounds.width, bounds.x + bounds.width);
        const double maxY = std::max(annotation.bounds.y + annotation.bounds.height, bounds.y + bounds.height);
        annotation.bounds.x = std::min(annotation.bounds.x, bounds.x);
        annotation.bounds.y = std::min(annotation.bounds.y, bounds.y);
        annotation.bounds.width = maxX - annotation.bounds.x;
        annotation.bounds.height = maxY - annotation.bounds.y;
    }
    if (annotation.color.a == 0) {
        annotation.color = DefaultColor(kind);
    }
    return notes_.add(std::move(annotation));
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
    const Point user = PageViewToUser(page, pageView);
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
    annotation.bounds = Rect{user.x, user.y - height, width, height};
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
    if (selectedNote_.value == 0) {
        return;
    }
    for (const Annotation& note : notes_.annotations()) {
        if (note.id == selectedNote_) {
            return;
        }
    }
    selectedNote_ = {};
}

void DocumentSession::eraseAt(int pageIndex, const PageGeometry& page, Point pageView, double radius) {
    std::vector<AnnotationId> shapes;
    for (const Annotation& note : notes_.annotations()) {
        if (note.pageIndex == pageIndex && note.kind != AnnotationKind::Ink && HitsNote(note, page, pageView, radius)) {
            shapes.push_back(note.id);
        }
    }
    for (const AnnotationId id : shapes) {
        notes_.remove(id);
        if (selectedNote_ == id) {
            selectedNote_ = {};
        }
    }
    notes_.eraseNear(pageIndex, page, pageView, radius);
    bool selectedRemains = false;
    for (const Annotation& note : notes_.annotations()) {
        if (note.id == selectedNote_) {
            selectedRemains = true;
            break;
        }
    }
    if (!selectedRemains) {
        selectedNote_ = {};
    }
}

}  // namespace pager
