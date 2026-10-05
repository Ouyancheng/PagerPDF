#pragma once

#include "Annotation.hpp"
#include "Geometry.hpp"

#include <limits>
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
    // Appends samples and returns, for each input, the index of the committed sample that now
    // carries it (near-duplicates merge into the previous sample).
    std::vector<std::size_t> addCoalesced(const std::vector<InkSample>& samples);
    void setPredicted(const std::vector<InkSample>& samples);
    // Late Pencil data (UITouch estimated-property updates) for an already committed sample.
    bool updateSample(std::size_t index, float force, float altitude, float azimuth);
    const std::vector<InkSample>& committed() const { return committed_; }
    const std::vector<InkSample>& predicted() const { return predicted_; }
    std::vector<InkSample> display() const;
    // The committed samples, losslessly thinned. Rendering them yields the same ribbon the
    // user saw while drawing, so nothing shifts when the Pencil lifts.
    std::vector<InkSample> finish();
    void cancel();
    bool active() const { return active_; }

private:
    bool active_ = false;
    std::vector<InkSample> committed_;
    std::vector<InkSample> predicted_;
};

struct RibbonOptions {
    bool taperHead = true;
    bool taperTail = true;
};

// Pressure, tilt, and speed produce a PDF Expert-like ballpoint: mostly stable, with a
// modest darkening under load and a slight thinning when the Pencil is moving quickly.
float InkWidthForSample(const InkSample& sample, float baseWidth, bool pressure);
// Douglas-Peucker on position, optionally also keeping samples whose force deviates from the
// straight-line interpolation by more than `forceEpsilon`.
std::vector<InkSample> SimplifyStroke(const std::vector<InkSample>& samples, double epsilon,
                                      double forceEpsilon = std::numeric_limits<double>::infinity());
std::vector<InkSample> SmoothStroke(const std::vector<InkSample>& samples);
// Catmull-Rom resampling so the ribbon is a curve, not a polyline of raw Pencil samples.
std::vector<InkSample> ResampleStroke(const std::vector<InkSample>& samples, double spacing);
// Triangles in page-view coordinates, all wound the same way so that filling them as one
// non-zero path yields their union with no seams or double-alpha overlaps.
std::vector<Triangle> BuildRibbon(const std::vector<InkSample>& samples, const PageGeometry& page, float baseWidth,
                                  bool pressure, RibbonOptions options = {});

}  // namespace pager
