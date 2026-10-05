#pragma once

#import "CanvasController.h"
#import "PadDocument.h"

#include "Annotation.hpp"

@interface PadCanvasView : UIView

@property(nonatomic, readonly) PagerCanvasController *controller;

- (void)attachToDocument:(PadDocument *)document;
- (void)detachViewport;
- (void)syncFrameAndTiles;
// Scrolling or zoom finished: refresh tiles at the current zoom.
- (void)updateVisibleRect;
// Called continuously during a pinch: only cheap placeholder rasters are requested.
- (void)followVisibleRect;
- (void)updateOverlay;
// Notes, selection or search changed; tiles and chrome catch up on the next run-loop turn.
- (void)annotationsDidChange;
- (void)endTextEditing;
- (void)syncTextEditorStyle;
- (void)clearTextSelection;
- (void)applyMarkupKind:(pager::AnnotationKind)kind;
- (void)handleMemoryWarning;

@end
