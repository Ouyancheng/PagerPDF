#pragma once

#import <Cocoa/Cocoa.h>

@class PagerCanvasView;
@class PagerDocument;

// Undo routes to the notes history unless a text field or text view is being edited.
@interface PagerWindow : NSWindow
@end

@interface PagerWindowController : NSWindowController

- (instancetype)initWithDocument:(PagerDocument *)document;
@property(nonatomic, readonly) PagerCanvasView *canvasView;
@property(nonatomic, readonly) NSScrollView *scrollView;

- (void)zoomToFitWidth:(id)sender;
- (void)scrollToPage:(int)page userPoint:(double)x y:(double)y;

@end
