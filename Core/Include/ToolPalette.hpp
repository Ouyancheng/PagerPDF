#pragma once

#include "Annotation.hpp"

#include <string>
#include <vector>

namespace pager {

// Colours and sizes offered for each tool. Shared so the iPad dock and the Mac markup bar
// present identical choices.
std::vector<Color> PaletteColors(Tool tool);
std::vector<float> PaletteSizes(Tool tool);
// Short label for a size chip ("S"/"M"/"L", or the point size for text).
std::string PaletteSizeLabel(Tool tool, std::size_t index, float size);
bool ToolHasStyle(Tool tool);
// The tool whose style an existing annotation of `kind` follows.
Tool ToolForKind(AnnotationKind kind);
// Like ToolForKind, but tells marker ink (no pressure) from pen ink.
Tool ToolForAnnotation(const Annotation& note);
bool SameHue(Color a, Color b);

}  // namespace pager
