#include "AnnotationGeometry.hpp"

#include <algorithm>
#include <cmath>

namespace pager {
namespace {

double Distance(Point a, Point b) { return std::hypot(a.x - b.x, a.y - b.y); }

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

Rect PageViewRect(const PageGeometry& page, const Rect& user) {
    const Point a = UserToPageView(page, Point{user.x, user.y});
    const Point b = UserToPageView(page, Point{user.x + user.width, user.y + user.height});
    return BoundsOfPoints(a, b);
}

// Distance between segments ab and cd.
double SegmentDistance(Point a, Point b, Point c, Point d) {
    const double d1x = b.x - a.x;
    const double d1y = b.y - a.y;
    const double d2x = d.x - c.x;
    const double d2y = d.y - c.y;
    const double denominator = d1x * d2y - d1y * d2x;
    if (std::fabs(denominator) > 1e-12) {
        const double t = ((c.x - a.x) * d2y - (c.y - a.y) * d2x) / denominator;
        const double u = ((c.x - a.x) * d1y - (c.y - a.y) * d1x) / denominator;
        if (t >= 0 && t <= 1 && u >= 0 && u <= 1) {
            return 0;
        }
    }
    return std::min({DistanceToSegment(a, c, d), DistanceToSegment(b, c, d), DistanceToSegment(c, a, b),
                     DistanceToSegment(d, a, b)});
}

InkSample Lerp(const InkSample& a, const InkSample& b, double t) {
    InkSample sample = a;
    const float ft = static_cast<float>(t);
    sample.x = a.x + (b.x - a.x) * t;
    sample.y = a.y + (b.y - a.y) * t;
    sample.force = a.force + (b.force - a.force) * ft;
    sample.altitude = a.altitude + (b.altitude - a.altitude) * ft;
    sample.azimuth = a.azimuth + (b.azimuth - a.azimuth) * ft;
    sample.speed = a.speed + (b.speed - a.speed) * ft;
    sample.time = a.time + (b.time - a.time) * t;
    sample.predicted = false;
    return sample;
}

Rect CapsuleBounds(Point from, Point to, double radius) {
    Rect rect = BoundsOfPoints(from, to);
    return Rect{rect.x - radius, rect.y - radius, rect.width + radius * 2, rect.height + radius * 2};
}

}  // namespace

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

double StrokeHalfWidthBound(const Annotation& note) {
    const double width = note.lineWidth > 0 ? note.lineWidth : 1.5;
    if (note.kind == AnnotationKind::Ink && note.pressure) {
        // InkWidthForSample tops out near 1.7x the base width (hard press, flat Pencil).
        return width * 0.86;
    }
    return width * 0.5;
}

Rect PageViewPaintBounds(const PageGeometry& page, const Annotation& note) {
    Rect rect;
    if (note.kind == AnnotationKind::Ink && !note.samples.empty()) {
        Point first = UserToPageView(page, Point{note.samples.front().x, note.samples.front().y});
        rect = Rect{first.x, first.y, 0, 0};
        for (const InkSample& sample : note.samples) {
            const Point view = UserToPageView(page, Point{sample.x, sample.y});
            const double maxX = std::max(rect.x + rect.width, view.x);
            const double maxY = std::max(rect.y + rect.height, view.y);
            rect.x = std::min(rect.x, view.x);
            rect.y = std::min(rect.y, view.y);
            rect.width = maxX - rect.x;
            rect.height = maxY - rect.y;
        }
    } else if (note.kind == AnnotationKind::Line) {
        rect = BoundsOfPoints(UserToPageView(page, note.lineStart), UserToPageView(page, note.lineEnd));
    } else if (!note.quads.empty()) {
        bool first = true;
        for (const Quad& quad : note.quads) {
            for (const Point& corner : quad.v) {
                const Point view = UserToPageView(page, corner);
                if (first) {
                    rect = Rect{view.x, view.y, 0, 0};
                    first = false;
                    continue;
                }
                const double maxX = std::max(rect.x + rect.width, view.x);
                const double maxY = std::max(rect.y + rect.height, view.y);
                rect.x = std::min(rect.x, view.x);
                rect.y = std::min(rect.y, view.y);
                rect.width = maxX - rect.x;
                rect.height = maxY - rect.y;
            }
        }
    } else {
        rect = PageViewRect(page, note.bounds);
    }
    const double pad = StrokeHalfWidthBound(note) + 1.5;
    return Rect{rect.x - pad, rect.y - pad, rect.width + pad * 2, rect.height + pad * 2};
}

bool HitsAnnotation(const Annotation& note, const PageGeometry& page, Point pageView, double slop) {
    return HitsAnnotationAlong(note, page, pageView, pageView, slop);
}

bool HitsAnnotationAlong(const Annotation& note, const PageGeometry& page, Point from, Point to, double radius) {
    if (!PageViewPaintBounds(page, note).intersects(CapsuleBounds(from, to, radius))) {
        return false;
    }
    if (note.kind == AnnotationKind::Line) {
        const double reach = radius + StrokeHalfWidthBound(note);
        return SegmentDistance(from, to, UserToPageView(page, note.lineStart), UserToPageView(page, note.lineEnd)) <= reach;
    }
    if (note.kind == AnnotationKind::Ink) {
        const double reach = radius + StrokeHalfWidthBound(note);
        if (note.samples.size() == 1) {
            const Point only = UserToPageView(page, Point{note.samples[0].x, note.samples[0].y});
            return DistanceToSegment(only, from, to) <= reach;
        }
        Point previous = UserToPageView(page, Point{note.samples.front().x, note.samples.front().y});
        for (std::size_t index = 1; index < note.samples.size(); ++index) {
            const Point current = UserToPageView(page, Point{note.samples[index].x, note.samples[index].y});
            if (SegmentDistance(previous, current, from, to) <= reach) {
                return true;
            }
            previous = current;
        }
        return false;
    }
    // Area-like notes: probe along the capsule's spine.
    const double length = Distance(from, to);
    const int steps = std::max(1, static_cast<int>(std::ceil(length / std::max(0.5, radius * 0.5))));
    for (int step = 0; step <= steps; ++step) {
        const double t = static_cast<double>(step) / steps;
        const Point probe{from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t};
        if (!note.quads.empty() && (note.kind == AnnotationKind::Highlight || note.kind == AnnotationKind::Underline ||
                                    note.kind == AnnotationKind::StrikeOut)) {
            const Point user = PageViewToUser(page, probe);
            for (const Quad& quad : note.quads) {
                if (PointInQuad(user, quad)) {
                    return true;
                }
                for (int corner = 0, previous = 3; corner < 4; previous = corner++) {
                    if (DistanceToSegment(probe, UserToPageView(page, quad.v[previous]),
                                          UserToPageView(page, quad.v[corner])) <= radius) {
                        return true;
                    }
                }
            }
            continue;
        }
        Rect bounds = PageViewRect(page, note.bounds);
        bounds = Rect{bounds.x - radius, bounds.y - radius, bounds.width + radius * 2, bounds.height + radius * 2};
        if (note.kind == AnnotationKind::Circle) {
            const Point center = bounds.center();
            const double radiusX = std::max(1.0, bounds.width * 0.5);
            const double radiusY = std::max(1.0, bounds.height * 0.5);
            const double nx = (probe.x - center.x) / radiusX;
            const double ny = (probe.y - center.y) / radiusY;
            if (nx * nx + ny * ny <= 1) {
                return true;
            }
        } else if (bounds.contains(probe)) {
            return true;
        }
    }
    return false;
}

bool EraseInkAlong(const Annotation& ink, const PageGeometry& page, Point from, Point to, double radius,
                   std::vector<Annotation>* pieces) {
    if (ink.kind != AnnotationKind::Ink || ink.samples.empty()) {
        return false;
    }
    const double reach = radius + StrokeHalfWidthBound(ink);
    const Rect capsule = CapsuleBounds(from, to, reach);
    if (!PageViewPaintBounds(page, ink).intersects(capsule)) {
        return false;
    }
    struct Entry {
        InkSample sample;
        bool inside = false;
        bool synthetic = false;
    };
    auto viewOf = [&](const InkSample& sample) { return UserToPageView(page, Point{sample.x, sample.y}); };
    auto insideCapsule = [&](Point view) { return DistanceToSegment(view, from, to) <= reach; };

    std::vector<Entry> entries;
    entries.reserve(ink.samples.size() + 16);
    bool touched = false;
    const double step = std::max(0.2, reach * 0.2);
    for (std::size_t index = 0; index < ink.samples.size(); ++index) {
        const InkSample& sample = ink.samples[index];
        const Point view = viewOf(sample);
        const bool inside = insideCapsule(view);
        touched = touched || inside;
        entries.push_back(Entry{sample, inside, false});
        if (index + 1 == ink.samples.size()) {
            break;
        }
        const InkSample& next = ink.samples[index + 1];
        const Point nextView = viewOf(next);
        if (SegmentDistance(view, nextView, from, to) > reach) {
            continue;
        }
        // The capsule touches this segment: densify it so the cut lands within `step` of the
        // true boundary even when both endpoints lie outside.
        const double length = Distance(view, nextView);
        const int count = static_cast<int>(std::ceil(length / step));
        for (int sub = 1; sub < count; ++sub) {
            const double t = static_cast<double>(sub) / count;
            const InkSample mid = Lerp(sample, next, t);
            const bool midInside = insideCapsule(viewOf(mid));
            touched = touched || midInside;
            entries.push_back(Entry{mid, midInside, true});
        }
    }
    if (!touched) {
        return false;
    }
    std::vector<Annotation> result;
    std::size_t start = 0;
    while (start < entries.size()) {
        if (entries[start].inside) {
            ++start;
            continue;
        }
        std::size_t end = start;
        while (end + 1 < entries.size() && !entries[end + 1].inside) {
            ++end;
        }
        Annotation piece = ink;
        piece.id.value = 0;
        piece.samples.clear();
        double length = 0;
        for (std::size_t index = start; index <= end; ++index) {
            // Interior densified points are collinear with their neighbours; only the ones that
            // mark a cut are worth storing.
            if (entries[index].synthetic && index != start && index != end) {
                continue;
            }
            if (!piece.samples.empty()) {
                const InkSample& last = piece.samples.back();
                length += std::hypot(entries[index].sample.x - last.x, entries[index].sample.y - last.y);
            }
            piece.samples.push_back(entries[index].sample);
        }
        piece.cutStart = start == 0 ? ink.cutStart : true;
        piece.cutEnd = end + 1 == entries.size() ? ink.cutEnd : true;
        if (piece.samples.size() >= 2 && length > 0.25) {
            double minX = piece.samples.front().x;
            double minY = piece.samples.front().y;
            double maxX = minX;
            double maxY = minY;
            for (const InkSample& sample : piece.samples) {
                minX = std::min(minX, sample.x);
                minY = std::min(minY, sample.y);
                maxX = std::max(maxX, sample.x);
                maxY = std::max(maxY, sample.y);
            }
            piece.bounds = Rect{minX, minY, std::max(1.0, maxX - minX), std::max(1.0, maxY - minY)};
            result.push_back(std::move(piece));
        }
        start = end + 1;
    }
    if (pieces != nullptr) {
        *pieces = std::move(result);
    }
    return true;
}

}  // namespace pager
