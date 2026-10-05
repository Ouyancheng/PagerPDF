#pragma once

#include "Geometry.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace pager {

enum class AnnotationKind : std::uint8_t {
    Highlight,
    Underline,
    StrikeOut,
    Square,
    Circle,
    Line,
    FreeText,
    Ink,
};

enum class Tool : std::uint8_t {
    Scroll,
    SelectText,
    Highlight,
    Underline,
    StrikeOut,
    Square,
    Circle,
    Line,
    FreeText,
    Pen,
    Marker,
    Eraser,
    SelectNote,
};

struct AnnotationId {
    std::uint64_t value = 0;
    bool operator==(const AnnotationId& other) const { return value == other.value; }
};

struct InkSample {
    double x = 0;
    double y = 0;
    float force = 1;
    float altitude = 0;
    float azimuth = 0;
    float speed = 0;
    double time = 0;
    bool predicted = false;
};

struct Annotation {
    AnnotationId id;
    AnnotationKind kind = AnnotationKind::Highlight;
    int pageIndex = 0;
    std::string stableKey;
    Rect bounds;
    Color color;
    float lineWidth = 1;
    float fontSize = 14;
    float opacity = 1;
    std::string contents;
    std::vector<Quad> quads;
    Point lineStart;
    Point lineEnd;
    std::vector<InkSample> samples;
    bool pressure = false;
};

const char* AnnotationKindName(AnnotationKind kind);
bool AnnotationKindFromName(const std::string& name, AnnotationKind* kind);

}  // namespace pager
