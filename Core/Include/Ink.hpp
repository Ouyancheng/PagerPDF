#pragma once

#include "Annotation.hpp"
#include "Geometry.hpp"

#include <vector>

namespace pager {

struct Triangle {
    Point a;
    Point b;
    Point c;
};

class StrokeBuilder {
public:
    void begin(InkSample sample);
    void addCoalesced(const std::vector<InkSample>& samples);
    void setPredicted(const std::vector<InkSample>& samples);
    std::vector<InkSample> display() const;
    std::vector<InkSample> finish();
    void cancel();
    bool active() const { return active_; }

private:
    bool active_ = false;
    std::vector<InkSample> committed_;
    std::vector<InkSample> predicted_;
};

// Pressure, tilt, and speed produce a PDF Expert-like ballpoint: mostly stable, with a
// modest darkening under load and a slight thinning when the Pencil is moving quickly.
float InkWidthForSample(const InkSample& sample, float baseWidth, bool pressure);
std::vector<InkSample> SimplifyStroke(const std::vector<InkSample>& samples, double epsilon);
std::vector<InkSample> SmoothStroke(const std::vector<InkSample>& samples);
// Catmull-Rom resampling so the ribbon is a curve, not a polyline of raw Pencil samples.
std::vector<InkSample> ResampleStroke(const std::vector<InkSample>& samples, double spacing);
std::vector<Triangle> BuildRibbon(const std::vector<InkSample>& samples, const PageGeometry& page, float baseWidth,
                                  bool pressure);

}  // namespace pager
