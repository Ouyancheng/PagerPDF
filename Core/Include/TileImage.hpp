#pragma once

#include "TileCache.hpp"

#include <CoreGraphics/CGImage.h>

namespace pager {

CGImageRef CreateTileCGImage(const TileImage& tile);

}

