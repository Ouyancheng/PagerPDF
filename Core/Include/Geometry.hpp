#pragma once

#include <cstdint>
#include <string>

namespace pager {

struct Point {
    double x = 0;
    double y = 0;
};

struct Size {
    double width = 0;
    double height = 0;
};

struct Rect {
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;

    bool contains(Point p) const;
    bool intersects(const Rect& other) const;
    Point center() const;
};

struct Quad {
    Point v[4] = {};
};

struct Color {
    float r = 0;
    float g = 0;
    float b = 0;
    float a = 0;
};

enum class PageRotation : int {
    R0 = 0,
    R90 = 90,
    R180 = 180,
    R270 = 270,
};

struct PageGeometry {
    int index = 0;
    Rect mediaBox;
    Rect cropBox;
    PageRotation rotation = PageRotation::R0;
    double userUnit = 1;
    std::string label;
    std::string stableKey;
};

PageRotation RotationFromDegrees(int degrees);
Size DisplayedSize(const PageGeometry& page);
Point UserToPageView(const PageGeometry& page, Point user);
Point PageViewToUser(const PageGeometry& page, Point pageView);
Rect BoundsOfPoints(Point a, Point b);

}  // namespace pager
