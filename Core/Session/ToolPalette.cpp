#include "ToolPalette.hpp"

#include <cmath>
#include <cstdio>

namespace pager {

std::vector<Color> PaletteColors(Tool tool) {
    switch (tool) {
        case Tool::Marker:
            return {{1, 0.85f, 0.1f, 0.45f},
                    {1, 0.35f, 0.55f, 0.45f},
                    {0.35f, 0.85f, 0.35f, 0.45f},
                    {0.25f, 0.55f, 1, 0.45f},
                    {1, 0.55f, 0.15f, 0.45f}};
        case Tool::Highlight:
            return {{1, 0.84f, 0.12f, 0.42f},
                    {0.45f, 0.9f, 0.3f, 0.42f},
                    {1, 0.4f, 0.7f, 0.42f},
                    {0.35f, 0.65f, 1, 0.42f},
                    {1, 0.55f, 0.15f, 0.42f}};
        case Tool::Pen:
            return {{0.05f, 0.05f, 0.05f, 1}, {0.45f, 0.45f, 0.48f, 1}, {0.1f, 0.35f, 0.9f, 1},
                    {0.85f, 0.12f, 0.12f, 1}, {0.1f, 0.55f, 0.2f, 1},   {0.45f, 0.2f, 0.75f, 1}};
        default:
            return {{0.12f, 0.12f, 0.14f, 1}, {0.1f, 0.35f, 0.9f, 1}, {0.85f, 0.12f, 0.12f, 1},
                    {0.1f, 0.55f, 0.2f, 1},   {0.9f, 0.45f, 0.1f, 1}, {0.45f, 0.2f, 0.75f, 1}};
    }
}

std::vector<float> PaletteSizes(Tool tool) {
    switch (tool) {
        case Tool::FreeText:
            return {11, 14, 18, 24};
        case Tool::Pen:
            return {1.4f, 2.2f, 3.6f};
        case Tool::Marker:
            return {8, 14, 22};
        case Tool::Square:
        case Tool::Circle:
        case Tool::Line:
            return {1, 2, 4};
        default:
            return {};
    }
}

std::string PaletteSizeLabel(Tool tool, std::size_t index, float size) {
    if (tool == Tool::FreeText) {
        char buffer[16];
        std::snprintf(buffer, sizeof(buffer), "%.0f", size);
        return buffer;
    }
    static const char *labels[] = {"S", "M", "L", "XL"};
    return index < 4 ? labels[index] : "?";
}

bool ToolHasStyle(Tool tool) {
    switch (tool) {
        case Tool::Highlight:
        case Tool::Underline:
        case Tool::StrikeOut:
        case Tool::Square:
        case Tool::Circle:
        case Tool::Line:
        case Tool::FreeText:
        case Tool::Pen:
        case Tool::Marker:
            return true;
        default:
            return false;
    }
}

Tool ToolForKind(AnnotationKind kind) {
    switch (kind) {
        case AnnotationKind::Highlight:
            return Tool::Highlight;
        case AnnotationKind::Underline:
            return Tool::Underline;
        case AnnotationKind::StrikeOut:
            return Tool::StrikeOut;
        case AnnotationKind::Circle:
            return Tool::Circle;
        case AnnotationKind::Line:
            return Tool::Line;
        case AnnotationKind::FreeText:
            return Tool::FreeText;
        case AnnotationKind::Ink:
            return Tool::Pen;
        case AnnotationKind::Square:
        default:
            return Tool::Square;
    }
}

Tool ToolForAnnotation(const Annotation &note) {
    if (note.kind == AnnotationKind::Ink && !note.pressure) {
        return Tool::Marker;
    }
    return ToolForKind(note.kind);
}

bool SameHue(Color a, Color b) {
    return std::fabs(a.r - b.r) < 0.08f && std::fabs(a.g - b.g) < 0.08f && std::fabs(a.b - b.b) < 0.08f;
}

}  // namespace pager
