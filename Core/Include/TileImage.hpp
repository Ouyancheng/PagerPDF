#pragma once

#include "TileCache.hpp"

#include <CoreGraphics/CGImage.h>

namespace pager {

// Returns a +1 reference to the tile's image (no pixel copy).
CGImageRef CreateTileCGImage(const TileImage& tile);

}
