#pragma once

#include <CoreGraphics/CGContext.h>
#include <CoreGraphics/CGGeometry.h>

namespace pager {

class PageRasterSource {
public:
    virtual ~PageRasterSource() = default;
    virtual void drawPage(int index, CGContextRef context, double pageWidth, double pageHeight) = 0;
};

}  // namespace pager
