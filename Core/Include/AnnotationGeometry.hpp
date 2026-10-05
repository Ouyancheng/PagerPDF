#pragma once

#include "Annotation.hpp"
#include "Geometry.hpp"

#include <vector>

namespace pager {

double DistanceToSegment(Point point, Point start, Point end);
// Upper bound on half the drawn stroke width, in page-view points.
double StrokeHalfWidthBound(const Annotation& note);
// Page-view rect covering everything the annotation paints, stroke width included.
Rect PageViewPaintBounds(const PageGeometry& page, const Annotation& note);
bool HitsAnnotation(const Annotation& note, const PageGeometry& page, Point pageView, double slop);
// True if any part of the capsule from `from` to `to` (page view) with `radius` touches the note.
bool HitsAnnotationAlong(const Annotation& note, const PageGeometry& page, Point from, Point to, double radius);
// Cuts the part of an ink stroke covered by the capsule. Returns false (and leaves `pieces`
// alone) if the stroke is untouched; otherwise `pieces` receives the surviving runs, which may
// be empty. Splits happen on segments, not just at samples, so a straight stroke stored as two
// samples can still be cut in the middle.
bool EraseInkAlong(const Annotation& ink, const PageGeometry& page, Point from, Point to, double radius,
                   std::vector<Annotation>* pieces);

}  // namespace pager
