#pragma once

#import "PDFKitPageSource.h"

#include "DocumentSession.hpp"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <string>
#include <vector>

// The document object a canvas renders (PadDocument on iPad, PagerDocument on Mac).
@protocol PagerSessionProvider <NSObject>
- (pager::DocumentSession &)session;
- (PDFKitPageSource *)source;
// Debounced, off-main-thread archive write.
- (void)saveNotes;
@end

typedef NS_ENUM(NSInteger, PagerGestureKind) {
    PagerGestureNone,
    // Pointer down on nothing editable: a tap (link, deselect) or the start of a pan.
    PagerGestureTap,
    PagerGestureHandle,
    PagerGestureTextSelection,
    PagerGestureShape,
    PagerGestureTextBox,
    PagerGestureEraser,
    PagerGestureInk,
};

// Platform glue: the UIKit and AppKit canvas views implement this.
@protocol PagerCanvasHost <NSObject>
// Visible part of the canvas in document (canvas) coordinates.
- (CGRect)canvasVisibleDocumentRect;
- (CGRect)canvasBounds;
- (double)canvasZoomScale;
- (CGFloat)canvasScreenScale;
// Live content appeared, disappeared or the view must be re-placed; cheap to call often.
- (void)canvasLiveContentChanged;
- (void)canvasInvalidateLiveRect:(CGRect)documentRect;
- (void)canvasSetPanSuspended:(BOOL)suspended;
// Show an in-place editor for a FreeText note, then call -beginEditingNote:isNew:.
- (void)canvasEditNote:(pager::AnnotationId)identifier isNew:(BOOL)isNew;
// Close the in-place editor (call -finishEditingWithText:).
- (void)canvasEndTextEditing;
// The edited note moved or changed style; re-place/re-style the editor.
- (void)canvasSyncTextEditor;
// The canvas finished a one-shot tool (a text box committed by pressing outside it).
- (void)canvasSelectTool:(pager::Tool)tool;
- (void)canvasOpenLink:(const pager::LinkHit &)link;
- (void)canvasBackgroundTapped;
- (void)canvasNotesChanged;
- (void)canvasSelectionChanged;
@end

// Platform-neutral canvas: page/tile/annotation layers, selection chrome, transient (live)
// content, and the annotation gestures every tool performs. Hosts feed it pointer events in
// document coordinates and draw its live content into their own view.
@interface PagerCanvasController : NSObject

- (instancetype)initWithPagesLayer:(CALayer *)pagesLayer
                       chromeLayer:(CALayer *)chromeLayer
                              host:(id<PagerCanvasHost>)host;

// Mac: dragging on the page with the Select tool selects text, and dragging a note moves
// it straight away (Preview behaviour). iPad: a finger drag pans and a tap selects.
@property(nonatomic) BOOL pointerSelectsText;
@property(nonatomic, readonly) BOOL zooming;
@property(nonatomic, readonly, weak) id<PagerSessionProvider> document;
@property(nonatomic, readonly) pager::AnnotationId editingNoteId;

- (void)attachDocument:(id<PagerSessionProvider>)document;
- (void)detach;
// Final teardown from the host's dealloc: no blocks, no weak references to the host.
- (void)shutdown;

// Viewport.
- (void)visibleRectDidChange;
- (void)visibleRectDidChangeWhileZooming;
- (void)handleMemoryWarning;

// Content changed (notes, selection, search, style); coalesced to the next run-loop turn.
- (void)contentDidChange;
- (void)syncContentNow;
- (void)updateSelectionLayers;
- (void)updateChrome;

// Gestures, in document coordinates.
- (PagerGestureKind)beginGestureAt:(pager::Point)point clickCount:(NSInteger)clickCount;
- (void)moveGestureTo:(pager::Point)point;
- (void)endGestureAt:(pager::Point)point;
- (void)cancelGesture;
@property(nonatomic, readonly) PagerGestureKind gesture;
@property(nonatomic, readonly) int gesturePage;

// Ink input for PagerGestureInk (samples from -inkSampleAt:...).
- (pager::InkSample)inkSampleAt:(pager::Point)documentPoint
                          force:(float)force
                       altitude:(float)altitude
                        azimuth:(float)azimuth
                           time:(double)time
                      predicted:(BOOL)predicted;
- (std::vector<std::size_t>)beginInk:(const std::vector<pager::InkSample> &)samples
                           predicted:(const std::vector<pager::InkSample> &)predicted;
- (std::vector<std::size_t>)appendInk:(const std::vector<pager::InkSample> &)samples
                            predicted:(const std::vector<pager::InkSample> &)predicted;
- (void)updateInkSample:(std::size_t)index force:(float)force altitude:(float)altitude azimuth:(float)azimuth;

// Text selection and markup.
- (void)selectTextFrom:(pager::Point)start to:(pager::Point)end word:(BOOL)word;
- (BOOL)clearTextSelection;
- (void)applyMarkupKind:(pager::AnnotationKind)kind;

// Notes.
- (void)deleteSelectedNote;
- (BOOL)applyColorToSelection:(pager::Color)color;
- (BOOL)applySizeToSelection:(float)size;
- (void)holdNoteUntilRendered:(pager::AnnotationId)identifier;
- (CGRect)documentRectForNote:(const pager::Annotation &)note;
- (const pager::Annotation *)noteAt:(pager::Point)point;
- (NSInteger)handleAt:(pager::Point)point;

// In-place text editing (the host owns the editor view).
- (void)beginEditingNote:(pager::AnnotationId)identifier isNew:(BOOL)isNew;
- (void)editingTextDidChange:(const std::string &)text;
- (void)finishEditingWithText:(const std::string &)text;

// Live content, drawn by the host into a y-down context in document coordinates.
- (BOOL)liveHasContent;
- (void)drawLiveInContext:(CGContextRef)context documentRect:(CGRect)rect;

// Diagnostics for tests.
- (NSUInteger)tileLayerCount;
- (NSUInteger)annotationLayerCount;

@end
