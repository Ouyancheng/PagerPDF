#include "Geometry.hpp"

#include <algorithm>
#include <cmath>

namespace pager {

bool Rect::contains(Point p) const {
    return p.x >= x && p.y >= y && p.x <= x + width && p.y <= y + height;
}

bool Rect::intersects(const Rect& other) const {
    return x < other.x + other.width && x + width > other.x && y < other.y + other.height && y + height > other.y;
}

Point Rect::center() const {
    return Point{x + width * 0.5, y + height * 0.5};
}

Rect Rect::united(const Rect& other) const {
    if (other.empty()) {
        return *this;
    }
    if (empty()) {
        return other;
    }
    const double minX = std::min(x, other.x);
    const double minY = std::min(y, other.y);
    const double maxX = std::max(x + width, other.x + other.width);
    const double maxY = std::max(y + height, other.y + other.height);
    return Rect{minX, minY, maxX - minX, maxY - minY};
}

Rect Rect::intersection(const Rect& other) const {
    const double minX = std::max(x, other.x);
    const double minY = std::max(y, other.y);
    const double maxX = std::min(x + width, other.x + other.width);
    const double maxY = std::min(y + height, other.y + other.height);
    if (maxX <= minX || maxY <= minY) {
        return Rect{};
    }
    return Rect{minX, minY, maxX - minX, maxY - minY};
}

PageRotation RotationFromDegrees(int degrees) {
    int normalized = ((degrees % 360) + 360) % 360;
    switch (normalized) {
        case 90:
            return PageRotation::R90;
        case 180:
            return PageRotation::R180;
        case 270:
            return PageRotation::R270;
        default:
            return PageRotation::R0;
    }
}

Size DisplayedSize(const PageGeometry& page) {
    const double unit = page.userUnit == 0 ? 1 : page.userUnit;
    const double width = page.cropBox.width * unit;
    const double height = page.cropBox.height * unit;
    if (page.rotation == PageRotation::R90 || page.rotation == PageRotation::R270) {
        return Size{height, width};
    }
    return Size{width, height};
}

Point UserToPageView(const PageGeometry& page, Point user) {
    const double unit = page.userUnit == 0 ? 1 : page.userUnit;
    const double lx = (user.x - page.cropBox.x) * unit;
    const double ly = (user.y - page.cropBox.y) * unit;
    const double width = page.cropBox.width * unit;
    const double height = page.cropBox.height * unit;
    switch (page.rotation) {
        case PageRotation::R90:
            return Point{ly, lx};
        case PageRotation::R180:
            return Point{width - lx, ly};
        case PageRotation::R270:
            return Point{height - ly, width - lx};
        case PageRotation::R0:
        default:
            return Point{lx, height - ly};
    }
}

Point PageViewToUser(const PageGeometry& page, Point pageView) {
    const double unit = page.userUnit == 0 ? 1 : page.userUnit;
    const double width = page.cropBox.width * unit;
    const double height = page.cropBox.height * unit;
    double lx = 0;
    double ly = 0;
    switch (page.rotation) {
        case PageRotation::R90:
            lx = pageView.y;
            ly = pageView.x;
            break;
        case PageRotation::R180:
            lx = width - pageView.x;
            ly = pageView.y;
            break;
        case PageRotation::R270:
            lx = width - pageView.y;
            ly = height - pageView.x;
            break;
        case PageRotation::R0:
        default:
            lx = pageView.x;
            ly = height - pageView.y;
            break;
    }
    return Point{page.cropBox.x + lx / unit, page.cropBox.y + ly / unit};
}

Rect BoundsOfPoints(Point a, Point b) {
    const double x = std::min(a.x, b.x);
    const double y = std::min(a.y, b.y);
    return Rect{x, y, std::abs(a.x - b.x), std::abs(a.y - b.y)};
}

}  // namespace pager
