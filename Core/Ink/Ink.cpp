#include "Ink.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace pager {
namespace {

constexpr double kMinSegment = 0.001;
constexpr double kDuplicateEpsilon = 0.06;
constexpr double kDrawSpacing = 0.7;
constexpr double kFinishSimplify = 0.16;
constexpr float kTaperHead = 10.0f;
constexpr float kTaperTail = 16.0f;

double Distance(Point a, Point b) {
    const double dx = a.x - b.x;
    const double dy = a.y - b.y;
    return std::sqrt(dx * dx + dy * dy);
}

float ClampFloat(float value, float lo, float hi) {
    return std::max(lo, std::min(hi, value));
}

void AnnotateSpeed(InkSample& sample, const InkSample& previous) {
    if (sample.time <= 0 || previous.time <= 0) {
        sample.speed = previous.speed;
        return;
    }
    const double dt = sample.time - previous.time;
    if (dt <= 1e-4) {
        sample.speed = previous.speed;
        return;
    }
    sample.speed = static_cast<float>(Distance(Point{sample.x, sample.y}, Point{previous.x, previous.y}) / dt);
}

bool NearlyDuplicate(const InkSample& a, const InkSample& b) {
    return Distance(Point{a.x, a.y}, Point{b.x, b.y}) < kDuplicateEpsilon &&
           std::fabs(a.force - b.force) < 0.04f;
}

float TaperScale(double distanceFromStart, double distanceFromEnd, double total) {
    float scale = 1;
    if (total > 0.5) {
        if (distanceFromStart < kTaperHead) {
            const float t = static_cast<float>(distanceFromStart / kTaperHead);
            scale = std::min(scale, 0.18f + 0.82f * t * t * (3 - 2 * t));
        }
        if (distanceFromEnd < kTaperTail) {
            const float t = static_cast<float>(distanceFromEnd / kTaperTail);
            scale = std::min(scale, 0.10f + 0.90f * t * t * (3 - 2 * t));
        }
    }
    return scale;
}

InkSample InterpolateCatmull(const InkSample& p0, const InkSample& p1, const InkSample& p2, const InkSample& p3,
                             double t) {
    const double t2 = t * t;
    const double t3 = t2 * t;
    auto blend = [&](double a, double b, double c, double d) {
        return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3);
    };
    auto blendF = [&](float a, float b, float c, float d) {
        return static_cast<float>(blend(a, b, c, d));
    };
    InkSample sample = p1;
    sample.x = blend(p0.x, p1.x, p2.x, p3.x);
    sample.y = blend(p0.y, p1.y, p2.y, p3.y);
    sample.force = std::max(0.0f, blendF(p0.force, p1.force, p2.force, p3.force));
    sample.altitude = std::max(0.0f, blendF(p0.altitude, p1.altitude, p2.altitude, p3.altitude));
    sample.azimuth = blendF(p0.azimuth, p1.azimuth, p2.azimuth, p3.azimuth);
    sample.speed = std::max(0.0f, blendF(p0.speed, p1.speed, p2.speed, p3.speed));
    sample.time = blend(p0.time, p1.time, p2.time, p3.time);
    sample.predicted = p1.predicted || p2.predicted;
    return sample;
}

void AppendQuad(std::vector<Triangle>& triangles, Point a, Point b, Point c, Point d) {
    triangles.push_back(Triangle{a, b, c});
    triangles.push_back(Triangle{b, d, c});
}

void AppendDisc(std::vector<Triangle>& triangles, Point center, float radius, int slices) {
    if (radius <= 0.02f) {
        return;
    }
    const int count = std::max(10, slices);
    Point previous{center.x + radius, center.y};
    for (int index = 1; index <= count; ++index) {
        const double angle = (2.0 * 3.14159265358979323846 * index) / count;
        const Point next{center.x + radius * std::cos(angle), center.y + radius * std::sin(angle)};
        triangles.push_back(Triangle{center, previous, next});
        previous = next;
    }
}

}  // namespace

float InkWidthForSample(const InkSample& sample, float baseWidth, bool pressure) {
    if (!pressure) {
        return baseWidth;
    }
    // Finger touches and not-yet-estimated Pencil samples report zero force; treat them as a
    // medium touch instead of collapsing the stroke to its minimum width.
    float force = sample.force;
    if (force <= 0.05f) {
        force = 0.55f;
    }
    force = ClampFloat(force, 0.08f, 1.45f);

    float tilt = 1;
    if (sample.altitude > 0.05f && sample.altitude < 1.6f) {
        // Vertical (~π/2) stays at 1; a flatter Pencil writes a slightly wider mark.
        tilt = 1 + ClampFloat(1.42f - sample.altitude, 0, 0.85f) * 0.2f;
    }

    float speed = 1;
    if (sample.speed > 8) {
        speed = ClampFloat(1 / (1 + (sample.speed - 8) * 0.012f), 0.62f, 1);
    }

    return baseWidth * (0.46f + 0.68f * force) * tilt * speed;
}

namespace {

void SimplifyRange(const std::vector<InkSample>& samples, std::size_t start, std::size_t end, double epsilon,
                   std::vector<char>& keep) {
    if (end <= start + 1) {
        return;
    }
    const Point a{samples[start].x, samples[start].y};
    const Point b{samples[end].x, samples[end].y};
    const double dx = b.x - a.x;
    const double dy = b.y - a.y;
    const double length = std::sqrt(dx * dx + dy * dy);
    double maxDistance = 0;
    std::size_t maxIndex = start;
    for (std::size_t index = start + 1; index < end; ++index) {
        const Point p{samples[index].x, samples[index].y};
        double distance = 0;
        if (length < 0.0001) {
            distance = Distance(a, p);
        } else {
            distance = std::abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length;
        }
        if (distance > maxDistance) {
            maxDistance = distance;
            maxIndex = index;
        }
    }
    if (maxDistance > epsilon) {
        keep[maxIndex] = 1;
        SimplifyRange(samples, start, maxIndex, epsilon, keep);
        SimplifyRange(samples, maxIndex, end, epsilon, keep);
    }
}

}  // namespace

void StrokeBuilder::begin(InkSample sample) {
    active_ = true;
    committed_.clear();
    predicted_.clear();
    sample.predicted = false;
    sample.speed = 0;
    committed_.push_back(sample);
}

void StrokeBuilder::addCoalesced(const std::vector<InkSample>& samples) {
    predicted_.clear();
    for (InkSample sample : samples) {
        sample.predicted = false;
        if (!committed_.empty()) {
            AnnotateSpeed(sample, committed_.back());
            if (NearlyDuplicate(committed_.back(), sample)) {
                committed_.back().force = sample.force;
                committed_.back().altitude = sample.altitude;
                committed_.back().azimuth = sample.azimuth;
                committed_.back().time = sample.time;
                committed_.back().speed = sample.speed;
                continue;
            }
        }
        committed_.push_back(sample);
    }
}

void StrokeBuilder::setPredicted(const std::vector<InkSample>& samples) {
    predicted_.clear();
    InkSample previous = committed_.empty() ? InkSample{} : committed_.back();
    bool havePrevious = !committed_.empty();
    for (InkSample sample : samples) {
        sample.predicted = true;
        if (havePrevious) {
            AnnotateSpeed(sample, previous);
        }
        predicted_.push_back(sample);
        previous = sample;
        havePrevious = true;
    }
}

std::vector<InkSample> StrokeBuilder::display() const {
    std::vector<InkSample> all = committed_;
    all.insert(all.end(), predicted_.begin(), predicted_.end());
    return all;
}

std::vector<InkSample> StrokeBuilder::finish() {
    active_ = false;
    predicted_.clear();
    std::vector<InkSample> simplified = SimplifyStroke(SmoothStroke(SmoothStroke(committed_)), kFinishSimplify);
    committed_.clear();
    return simplified;
}

void StrokeBuilder::cancel() {
    active_ = false;
    committed_.clear();
    predicted_.clear();
}

std::vector<InkSample> SmoothStroke(const std::vector<InkSample>& samples) {
    if (samples.size() < 3) {
        return samples;
    }
    // Light 3-point moving average over position and force to hide Pencil sampling jitter
    // without lagging behind the stroke. Endpoints are preserved.
    std::vector<InkSample> smoothed = samples;
    for (std::size_t index = 1; index + 1 < samples.size(); ++index) {
        const InkSample& previous = samples[index - 1];
        const InkSample& current = samples[index];
        const InkSample& next = samples[index + 1];
        smoothed[index].x = current.x * 0.5 + (previous.x + next.x) * 0.25;
        smoothed[index].y = current.y * 0.5 + (previous.y + next.y) * 0.25;
        smoothed[index].force = current.force * 0.5f + (previous.force + next.force) * 0.25f;
        smoothed[index].altitude = current.altitude * 0.5f + (previous.altitude + next.altitude) * 0.25f;
        smoothed[index].speed = current.speed * 0.5f + (previous.speed + next.speed) * 0.25f;
    }
    return smoothed;
}

std::vector<InkSample> SimplifyStroke(const std::vector<InkSample>& samples, double epsilon) {
    if (samples.size() < 3) {
        return samples;
    }
    std::vector<char> keep(samples.size(), 0);
    keep.front() = 1;
    keep.back() = 1;
    SimplifyRange(samples, 0, samples.size() - 1, epsilon, keep);
    std::vector<InkSample> simplified;
    for (std::size_t index = 0; index < samples.size(); ++index) {
        if (keep[index]) {
            simplified.push_back(samples[index]);
        }
    }
    return simplified;
}

std::vector<InkSample> ResampleStroke(const std::vector<InkSample>& samples, double spacing) {
    if (samples.size() < 2) {
        return samples;
    }
    const double step = spacing > 0.05 ? spacing : kDrawSpacing;
    std::vector<InkSample> out;
    out.reserve(samples.size() * 2);
    out.push_back(samples.front());
    for (std::size_t index = 0; index + 1 < samples.size(); ++index) {
        const InkSample& p0 = samples[index == 0 ? 0 : index - 1];
        const InkSample& p1 = samples[index];
        const InkSample& p2 = samples[index + 1];
        const InkSample& p3 = samples[std::min(index + 2, samples.size() - 1)];
        const double length = Distance(Point{p1.x, p1.y}, Point{p2.x, p2.y});
        const int segments = std::max(1, static_cast<int>(std::ceil(length / step)));
        for (int segment = 1; segment <= segments; ++segment) {
            if (index + 1 == samples.size() - 1 && segment == segments) {
                break;
            }
            out.push_back(InterpolateCatmull(p0, p1, p2, p3, static_cast<double>(segment) / segments));
        }
    }
    out.push_back(samples.back());
    return out;
}

std::vector<Triangle> BuildRibbon(const std::vector<InkSample>& samples, const PageGeometry& page, float baseWidth,
                                  bool pressure) {
    std::vector<Triangle> triangles;
    if (samples.empty()) {
        return triangles;
    }
    const std::vector<InkSample> curve = ResampleStroke(samples.size() >= 2 ? SmoothStroke(samples) : samples, kDrawSpacing);
    struct Vertex {
        Point point;
        float width = 0;
    };
    std::vector<Vertex> vertices;
    vertices.reserve(curve.size());
    std::vector<double> distances(curve.size(), 0);
    double total = 0;
    for (std::size_t index = 0; index < curve.size(); ++index) {
        const Point view = UserToPageView(page, Point{curve[index].x, curve[index].y});
        if (index > 0) {
            total += Distance(vertices.back().point, view);
            distances[index] = total;
        }
        vertices.push_back(Vertex{view, InkWidthForSample(curve[index], baseWidth, pressure)});
    }
    if (vertices.size() == 1) {
        AppendDisc(triangles, vertices.front().point, vertices.front().width * 0.5f, 16);
        return triangles;
    }
    for (std::size_t index = 0; index < vertices.size(); ++index) {
        vertices[index].width *= TaperScale(distances[index], total - distances[index], total);
    }
    // Smooth widths so pressure noise does not pinch the ribbon.
    if (vertices.size() >= 3) {
        std::vector<float> widths(vertices.size());
        widths.front() = vertices.front().width;
        widths.back() = vertices.back().width;
        for (std::size_t index = 1; index + 1 < vertices.size(); ++index) {
            widths[index] =
                vertices[index].width * 0.5f + (vertices[index - 1].width + vertices[index + 1].width) * 0.25f;
        }
        for (std::size_t index = 0; index < vertices.size(); ++index) {
            vertices[index].width = widths[index];
        }
    }

    std::vector<Point> left(vertices.size());
    std::vector<Point> right(vertices.size());
    Point lastNormal{0, 1};
    for (std::size_t index = 0; index < vertices.size(); ++index) {
        Point tangent;
        if (index == 0) {
            tangent = Point{vertices[1].point.x - vertices[0].point.x, vertices[1].point.y - vertices[0].point.y};
        } else if (index + 1 == vertices.size()) {
            tangent = Point{vertices[index].point.x - vertices[index - 1].point.x,
                            vertices[index].point.y - vertices[index - 1].point.y};
        } else {
            tangent = Point{vertices[index + 1].point.x - vertices[index - 1].point.x,
                            vertices[index + 1].point.y - vertices[index - 1].point.y};
        }
        double length = std::sqrt(tangent.x * tangent.x + tangent.y * tangent.y);
        if (length < kMinSegment) {
            tangent = Point{-lastNormal.y, lastNormal.x};
            length = 1;
        }
        Point normal{-tangent.y / length, tangent.x / length};
        if (index > 0 && (normal.x * lastNormal.x + normal.y * lastNormal.y) < 0) {
            normal.x = -normal.x;
            normal.y = -normal.y;
        }
        lastNormal = normal;
        const double half = vertices[index].width * 0.5;
        left[index] = Point{vertices[index].point.x + normal.x * half, vertices[index].point.y + normal.y * half};
        right[index] = Point{vertices[index].point.x - normal.x * half, vertices[index].point.y - normal.y * half};
    }
    for (std::size_t index = 0; index + 1 < vertices.size(); ++index) {
        AppendQuad(triangles, left[index], right[index], left[index + 1], right[index + 1]);
    }
    AppendDisc(triangles, vertices.front().point, vertices.front().width * 0.5f, 14);
    AppendDisc(triangles, vertices.back().point, vertices.back().width * 0.5f, 14);
    return triangles;
}

}  // namespace pager
