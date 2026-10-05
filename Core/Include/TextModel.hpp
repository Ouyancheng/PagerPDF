#pragma once

#include "Geometry.hpp"

#include <string>
#include <vector>

namespace pager {

struct SelectionQuad {
    int pageIndex = 0;
    Quad quad;
};

struct TextSelection {
    std::string text;
    std::vector<SelectionQuad> quads;
};

struct OutlineItem {
    std::string title;
    int pageIndex = -1;
    Point point;
    std::vector<OutlineItem> children;
};

struct LinkHit {
    bool found = false;
    bool hasDestination = false;
    int pageIndex = -1;
    Point point;
    std::string url;
};

}  // namespace pager
