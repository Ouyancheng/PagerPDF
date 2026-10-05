#pragma once

#import "PadDocument.h"

#include "Annotation.hpp"

@interface PadCanvasView : UIView

- (void)attachToDocument:(PadDocument *)document;
- (void)detachViewport;
- (void)syncFrameAndTiles;
- (void)updateVisibleRect;
- (void)followVisibleRect;
- (void)updateOverlay;
- (void)acceptTile:(pager::TileImage)tile;
- (void)endTextEditing;
- (void)syncTextEditorStyle;
- (void)clearTextSelection;
- (void)applyMarkupKind:(pager::AnnotationKind)kind;

@end
