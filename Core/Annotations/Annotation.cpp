#include "Annotation.hpp"

namespace pager {
namespace {

bool SamePoint(Point a, Point b) { return a.x == b.x && a.y == b.y; }

bool SameRect(const Rect& a, const Rect& b) {
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

bool SameColor(const Color& a, const Color& b) { return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a; }

}  // namespace

bool SameContent(const Annotation& a, const Annotation& b) {
    if (a.id.value != b.id.value || a.kind != b.kind || a.pageIndex != b.pageIndex || a.stableKey != b.stableKey ||
        !SameRect(a.bounds, b.bounds) || !SameColor(a.color, b.color) || a.lineWidth != b.lineWidth ||
        a.fontSize != b.fontSize || a.opacity != b.opacity || a.contents != b.contents ||
        !SamePoint(a.lineStart, b.lineStart) || !SamePoint(a.lineEnd, b.lineEnd) || a.pressure != b.pressure ||
        a.cutStart != b.cutStart || a.cutEnd != b.cutEnd || a.quads.size() != b.quads.size() ||
        a.samples.size() != b.samples.size()) {
        return false;
    }
    for (std::size_t index = 0; index < a.quads.size(); ++index) {
        for (int corner = 0; corner < 4; ++corner) {
            if (!SamePoint(a.quads[index].v[corner], b.quads[index].v[corner])) {
                return false;
            }
        }
    }
    for (std::size_t index = 0; index < a.samples.size(); ++index) {
        const InkSample& p = a.samples[index];
        const InkSample& q = b.samples[index];
        if (p.x != q.x || p.y != q.y || p.force != q.force || p.altitude != q.altitude) {
            return false;
        }
    }
    return true;
}

const char* AnnotationKindName(AnnotationKind kind) {
    switch (kind) {
        case AnnotationKind::Highlight:
            return "Highlight";
        case AnnotationKind::Underline:
            return "Underline";
        case AnnotationKind::StrikeOut:
            return "StrikeOut";
        case AnnotationKind::Square:
            return "Square";
        case AnnotationKind::Circle:
            return "Circle";
        case AnnotationKind::Line:
            return "Line";
        case AnnotationKind::FreeText:
            return "FreeText";
        case AnnotationKind::Ink:
            return "Ink";
    }
    return "Highlight";
}

bool AnnotationKindFromName(const std::string& name, AnnotationKind* kind) {
    if (kind == nullptr) {
        return false;
    }
    if (name == "Highlight") {
        *kind = AnnotationKind::Highlight;
    } else if (name == "Underline") {
        *kind = AnnotationKind::Underline;
    } else if (name == "StrikeOut") {
        *kind = AnnotationKind::StrikeOut;
    } else if (name == "Square") {
        *kind = AnnotationKind::Square;
    } else if (name == "Circle") {
        *kind = AnnotationKind::Circle;
    } else if (name == "Line") {
        *kind = AnnotationKind::Line;
    } else if (name == "FreeText" || name == "Text") {
        *kind = AnnotationKind::FreeText;
    } else if (name == "Ink") {
        *kind = AnnotationKind::Ink;
    } else {
        return false;
    }
    return true;
}

}  // namespace pager
