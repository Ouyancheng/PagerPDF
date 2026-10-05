#pragma once

#import "CanvasController.h"
#import "PagerDocument.h"

#import <Cocoa/Cocoa.h>

@class PagerCanvasView;

@protocol PagerCanvasViewDelegate <NSObject>
- (void)canvasViewNotesChanged:(PagerCanvasView *)canvas;
- (void)canvasViewSelectionChanged:(PagerCanvasView *)canvas;
- (void)canvasView:(PagerCanvasView *)canvas openLink:(const pager::LinkHit &)link;
- (void)canvasView:(PagerCanvasView *)canvas smartMagnifyAt:(NSPoint)documentPoint;
- (void)canvasView:(PagerCanvasView *)canvas selectTool:(pager::Tool)tool;
@end

// AppKit host for PagerCanvasController. Lives as the document view of an NSScrollView whose
// magnification is the zoom; coordinates are document points, y down.
@interface PagerCanvasView : NSView

@property(nonatomic, weak) id<PagerCanvasViewDelegate> delegate;
@property(nonatomic, readonly) PagerCanvasController *controller;

- (void)attachToDocument:(PagerDocument *)document;
- (void)detach;
- (void)syncFrame;
// Scrolling or zooming settled: tiles at the current magnification.
- (void)visibleRectDidChange;
// Live pinch in progress: only cheap placeholder rasters.
- (void)visibleRectDidChangeWhileZooming;
- (void)endTextEditing;
- (void)editSelectedNote;

@end
