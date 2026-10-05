#include "Annotation.hpp"

namespace pager {

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
