#import "PagerCanvasView.h"

#import "ToolPalette.hpp"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cctype>
#include <cmath>

namespace {

constexpr double kMaxLivePixels = 16.0e6;

NSDictionary *NoActions() {
    static NSDictionary *actions = @{
        @"contents" : NSNull.null,
        @"bounds" : NSNull.null,
        @"position" : NSNull.null,
        @"frame" : NSNull.null,
        @"sublayers" : NSNull.null,
        @"hidden" : NSNull.null,
        @"contentsScale" : NSNull.null,
    };
    return actions;
}

NSImage *Swatch(pager::Color color) {
    return [NSImage imageWithSize:NSMakeSize(14, 14)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       [[NSColor colorWithSRGBRed:color.r green:color.g blue:color.b alpha:std::max(0.45f, color.a)] setFill];
                       [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1, 1)] fill];
                       return YES;
                   }];
}

NSString *TrimmedSelectionText(const pager::DocumentSession &session) {
    if (session.selection().text.empty()) {
        return @"";
    }
    return [@(session.selection().text.c_str())
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *GoogleSearchTitle(NSString *query) {
    if (query.length == 0) {
        return @"Search with Google";
    }
    NSString *snippet = query;
    if (snippet.length > 28) {
        snippet = [[snippet substringToIndex:28] stringByAppendingString:@"…"];
    }
    return [NSString stringWithFormat:@"Search Google for “%@”", snippet];
}

NSURL *GoogleSearchURL(NSString *query) {
    if (query.length == 0) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.google.com/search"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:query]];
    return components.URL;
}

BOOL ToolAllowsTextLookUp(pager::Tool tool) {
    switch (tool) {
        case pager::Tool::Scroll:
        case pager::Tool::SelectNote:
        case pager::Tool::SelectText:
        case pager::Tool::Highlight:
        case pager::Tool::Underline:
        case pager::Tool::StrikeOut:
            return YES;
        default:
            return NO;
    }
}

BOOL SelectionContainsDocumentPoint(const pager::DocumentSession &session, pager::Point document) {
    const pager::Layout &layout = session.viewport().layout();
    const int pageIndex = layout.pageAt(document);
    if (pageIndex < 0) {
        return NO;
    }
    const pager::PageGeometry *page = session.viewport().geometry(pageIndex);
    if (page == nullptr) {
        return NO;
    }
    const pager::Rect frame = layout.pageFrame(pageIndex);
    const pager::Point user =
        pager::PageViewToUser(*page, pager::Point{document.x - frame.x, document.y - frame.y});
    for (const pager::SelectionQuad &quad : session.selection().quads) {
        if (quad.pageIndex != pageIndex) {
            continue;
        }
        const pager::Rect bounds = pager::BoundsOfPoints(quad.quad.v[0], quad.quad.v[2]).united(
            pager::BoundsOfPoints(quad.quad.v[1], quad.quad.v[3]));
        if (bounds.contains(user)) {
            return YES;
        }
    }
    return NO;
}

}  // namespace

// A layer-hosting view whose sublayers use the canvas's top-down document coordinates.
@interface PagerLayerHostView : NSView
@end

@implementation PagerLayerHostView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        CALayer *layer = [CALayer layer];
        layer.geometryFlipped = YES;
        layer.actions = NoActions();
        self.layer = layer;
        self.wantsLayer = YES;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

@end

@interface PagerLiveDrawer : NSObject <CALayerDelegate>
@property(nonatomic, weak) PagerCanvasController *controller;
@end

@implementation PagerLiveDrawer

- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context {
    // The live content draws y-down in document points. Core Animation hands over a y-up
    // context unless it already flipped it for the flipped host.
    if (CGContextGetCTM(context).d > 0) {
        CGContextTranslateCTM(context, 0, layer.bounds.size.height);
        CGContextScaleCTM(context, 1, -1);
    }
    const CGRect clip = CGContextGetClipBoundingBox(context);
    const CGPoint origin = layer.frame.origin;
    CGContextTranslateCTM(context, -origin.x, -origin.y);
    [self.controller drawLiveInContext:context documentRect:CGRectOffset(clip, origin.x, origin.y)];
}

- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
    return (id<CAAction>)NSNull.null;
}

@end

@interface PagerCanvasView () <PagerCanvasHost, NSTextViewDelegate, NSMenuItemValidation>
@end

@implementation PagerCanvasView {
    __weak PagerDocument *_document;
    PagerCanvasController *_controller;
    PagerLayerHostView *_pagesHost;
    PagerLayerHostView *_chromeHost;
    PagerLayerHostView *_liveHost;
    CALayer *_liveLayer;
    PagerLiveDrawer *_liveDrawer;
    NSTextView *_textEditor;
    NSTrackingArea *_tracking;
    BOOL _forceClickLookUpShown;
    BOOL _pressedOnSelection;
    pager::TextSelection _pressedSelection;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
        _pagesHost = [[PagerLayerHostView alloc] initWithFrame:self.bounds];
        _chromeHost = [[PagerLayerHostView alloc] initWithFrame:self.bounds];
        _liveHost = [[PagerLayerHostView alloc] initWithFrame:self.bounds];
        for (NSView *host in @[_pagesHost, _chromeHost, _liveHost]) {
            host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [self addSubview:host];
        }
        _controller = [[PagerCanvasController alloc] initWithPagesLayer:_pagesHost.layer
                                                            chromeLayer:_chromeHost.layer
                                                                   host:self];
        _controller.pointerSelectsText = YES;
        _liveDrawer = [[PagerLiveDrawer alloc] init];
        _liveDrawer.controller = _controller;
        _liveLayer = [CALayer layer];
        _liveLayer.delegate = _liveDrawer;
        _liveLayer.hidden = YES;
        _liveLayer.needsDisplayOnBoundsChange = YES;
        [_liveHost.layer addSublayer:_liveLayer];
    }
    return self;
}

- (void)dealloc {
    [_controller shutdown];
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (PagerCanvasController *)controller {
    return _controller;
}

#pragma mark - Document lifetime

- (void)attachToDocument:(PagerDocument *)document {
    [self detach];
    _document = document;
    [_controller attachDocument:document];
    [self syncFrame];
}

- (void)detach {
    [_controller detach];
    _document = nil;
}

- (void)syncFrame {
    if (_document == nil) {
        return;
    }
    const pager::Size content = _document.session.viewport().layout().contentSize();
    [self setFrameSize:NSMakeSize(std::max(1.0, content.width), std::max(1.0, content.height))];
    [self visibleRectDidChange];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self visibleRectDidChange];
}

- (void)visibleRectDidChange {
    [_controller visibleRectDidChange];
    [self.window invalidateCursorRectsForView:self];
}

- (void)visibleRectDidChangeWhileZooming {
    [_controller visibleRectDidChangeWhileZooming];
}

#pragma mark - PagerCanvasHost

- (CGRect)canvasVisibleDocumentRect {
    return NSRectToCGRect(self.visibleRect);
}

- (CGRect)canvasBounds {
    return NSRectToCGRect(self.bounds);
}

- (double)canvasZoomScale {
    NSScrollView *scroll = self.enclosingScrollView;
    return scroll == nil ? 1 : std::max(0.05, static_cast<double>(scroll.magnification));
}

- (CGFloat)canvasScreenScale {
    return self.window.backingScaleFactor ?: (NSScreen.mainScreen.backingScaleFactor ?: 2);
}

- (void)canvasLiveContentChanged {
    if (![_controller liveHasContent]) {
        if (!_liveLayer.hidden) {
            _liveLayer.hidden = YES;
            _liveLayer.contents = nil;
        }
        return;
    }
    if (_controller.zooming && !_liveLayer.hidden) {
        return;
    }
    const CGRect visible = CGRectIntersection(NSRectToCGRect(self.visibleRect), NSRectToCGRect(self.bounds));
    if (CGRectIsEmpty(visible)) {
        return;
    }
    const CGRect frame = CGRectIntegral(visible);
    double scale = [self canvasScreenScale] * [self canvasZoomScale];
    const double pixels = frame.size.width * frame.size.height * scale * scale;
    if (pixels > kMaxLivePixels) {
        scale *= std::sqrt(kMaxLivePixels / pixels);
    }
    if (!CGRectEqualToRect(frame, _liveLayer.frame) || std::fabs(_liveLayer.contentsScale - scale) > 1e-3 ||
        _liveLayer.hidden) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _liveLayer.frame = frame;
        _liveLayer.contentsScale = scale;
        _liveLayer.hidden = NO;
        [CATransaction commit];
        [_liveLayer setNeedsDisplay];
    }
}

- (void)canvasInvalidateLiveRect:(CGRect)documentRect {
    if (_liveLayer.hidden) {
        return;
    }
    const CGRect frame = _liveLayer.frame;
    [_liveLayer setNeedsDisplayInRect:CGRectIntegral(CGRectOffset(documentRect, -frame.origin.x, -frame.origin.y))];
}

- (void)canvasSetPanSuspended:(BOOL)suspended {
}

- (void)canvasEditNote:(pager::AnnotationId)identifier isNew:(BOOL)isNew {
    [self endTextEditing];
    const pager::Annotation *note = _document == nil ? nullptr : _document.session.notes().find(identifier);
    if (note == nullptr || note->kind != pager::AnnotationKind::FreeText) {
        return;
    }
    _textEditor = [[NSTextView alloc] initWithFrame:NSInsetRect(NSRectFromCGRect([_controller documentRectForNote:*note]), 4, 3)];
    _textEditor.drawsBackground = NO;
    _textEditor.richText = NO;
    _textEditor.allowsUndo = YES;
    _textEditor.textContainerInset = NSMakeSize(2, 2);
    _textEditor.textContainer.lineFragmentPadding = 0;
    _textEditor.string = @(note->contents.c_str()) ?: @"";
    _textEditor.delegate = self;
    [self applyEditorStyleFromNote:*note];
    [self addSubview:_textEditor];
    [_controller beginEditingNote:identifier isNew:isNew];
    [self.window makeFirstResponder:_textEditor];
}

- (void)canvasEndTextEditing {
    [self endTextEditing];
}

- (void)canvasSyncTextEditor {
    const pager::AnnotationId editing = _controller.editingNoteId;
    if (_document == nil || _textEditor == nil || editing.value == 0) {
        return;
    }
    const pager::Annotation *note = _document.session.notes().find(editing);
    if (note == nullptr) {
        [self endTextEditing];
        return;
    }
    _textEditor.frame = NSInsetRect(NSRectFromCGRect([_controller documentRectForNote:*note]), 4, 3);
    [self applyEditorStyleFromNote:*note];
}

- (void)canvasOpenLink:(const pager::LinkHit &)link {
    [self.delegate canvasView:self openLink:link];
}

- (void)canvasSelectTool:(pager::Tool)tool {
    [self.delegate canvasView:self selectTool:tool];
}

- (void)canvasBackgroundTapped {
}

- (void)canvasNotesChanged {
    [self.delegate canvasViewNotesChanged:self];
}

- (void)canvasSelectionChanged {
    [self.delegate canvasViewSelectionChanged:self];
}

#pragma mark - Text editor

- (void)applyEditorStyleFromNote:(const pager::Annotation &)note {
    const CGFloat size = std::max(8.0f, note.fontSize > 0 ? note.fontSize : 14);
    NSFont *font = [NSFont fontWithName:@"Helvetica" size:size] ?: [NSFont systemFontOfSize:size];
    NSColor *color = [NSColor colorWithSRGBRed:note.color.r green:note.color.g blue:note.color.b
                                         alpha:note.color.a == 0 ? 1 : note.color.a];
    _textEditor.font = font;
    _textEditor.textColor = color;
    _textEditor.insertionPointColor = color;
    _textEditor.typingAttributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : color};
}

- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == _textEditor) {
        [_controller editingTextDidChange:_textEditor.string.UTF8String ?: ""];
    }
}

- (void)textDidEndEditing:(NSNotification *)notification {
    NSTextView *editor = notification.object;
    if (editor == _textEditor) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_textEditor == editor) {
                [self endTextEditing];
            }
        });
    }
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (textView == _textEditor && selector == @selector(cancelOperation:)) {
        [self endTextEditing];
        if (_document != nil && _document.session.tool() == pager::Tool::FreeText) {
            [self.delegate canvasView:self selectTool:pager::Tool::Scroll];
        }
        return YES;
    }
    return NO;
}

- (void)endTextEditing {
    if (_textEditor == nil) {
        return;
    }
    NSTextView *editor = _textEditor;
    _textEditor = nil;
    if (self.window.firstResponder == editor) {
        [self.window makeFirstResponder:self];
    }
    [editor removeFromSuperview];
    [_controller finishEditingWithText:editor.string.UTF8String ?: ""];
}

- (void)editSelectedNote {
    const pager::Annotation *note = _document == nil ? nullptr : _document.session.selectedAnnotation();
    if (note != nullptr && note->kind == pager::AnnotationKind::FreeText) {
        [self canvasEditNote:note->id isNew:NO];
    }
}

#pragma mark - Mouse

- (pager::Point)documentPoint:(NSEvent *)event {
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    return pager::Point{point.x, point.y};
}

- (pager::InkSample)sampleFrom:(NSEvent *)event {
    float force = 0;
    float altitude = 0;
    if (event.subtype == NSEventSubtypeTabletPoint) {
        // Tablet pressure is 0…1 with ~0.5 for a normal stroke; Pencil-style force puts an
        // average stroke near 1.
        force = event.pressure * 2;
        const NSPoint tilt = event.tilt;
        altitude = static_cast<float>(M_PI_2 * (1 - std::min(1.0, std::hypot(tilt.x, tilt.y))));
    }
    return [_controller inkSampleAt:[self documentPoint:event]
                              force:force
                           altitude:altitude
                            azimuth:0
                               time:event.timestamp
                          predicted:NO];
}

- (void)mouseDown:(NSEvent *)event {
    _forceClickLookUpShown = NO;
    _pressedOnSelection = NO;
    _pressedSelection = {};
    if (_document == nil) {
        return;
    }
    if (self.window.firstResponder != self && self.window.firstResponder != _textEditor) {
        [self.window makeFirstResponder:self];
    }
    const pager::Point document = [self documentPoint:event];
    if (TrimmedSelectionText(_document.session).length > 0 &&
        SelectionContainsDocumentPoint(_document.session, document)) {
        _pressedOnSelection = YES;
        _pressedSelection = _document.session.selection();
    }
    const PagerGestureKind gesture = [_controller beginGestureAt:document clickCount:event.clickCount];
    if (gesture == PagerGestureInk) {
        [_controller beginInk:std::vector<pager::InkSample>{[self sampleFrom:event]} predicted:std::vector<pager::InkSample>{}];
    }
    [self updateCursorFor:event];
}

- (void)mouseDragged:(NSEvent *)event {
    const PagerGestureKind gesture = _controller.gesture;
    if (gesture == PagerGestureNone) {
        return;
    }
    if (gesture == PagerGestureInk) {
        [_controller appendInk:std::vector<pager::InkSample>{[self sampleFrom:event]} predicted:std::vector<pager::InkSample>{}];
        return;
    }
    if (gesture == PagerGestureTextSelection || gesture == PagerGestureHandle || gesture == PagerGestureShape) {
        [self autoscroll:event];
    }
    [_controller moveGestureTo:[self documentPoint:event]];
}

- (void)mouseUp:(NSEvent *)event {
    if (_controller.gesture == PagerGestureInk) {
        [_controller appendInk:std::vector<pager::InkSample>{[self sampleFrom:event]} predicted:std::vector<pager::InkSample>{}];
    }
    [_controller endGestureAt:[self documentPoint:event]];
    [self updateCursorFor:event];
}

- (void)smartMagnifyWithEvent:(NSEvent *)event {
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.delegate canvasView:self smartMagnifyAt:point];
}

#pragma mark - Force click / Look Up

- (NSPoint)selectionBaselineInView {
    if (_document == nil || _document.session.selection().quads.empty()) {
        return NSMakePoint(NSMidX(self.visibleRect), NSMidY(self.visibleRect));
    }
    const pager::SelectionQuad &quad = _document.session.selection().quads.front();
    const pager::PageGeometry *page = _document.session.viewport().geometry(quad.pageIndex);
    if (page == nullptr) {
        return NSMakePoint(NSMidX(self.visibleRect), NSMidY(self.visibleRect));
    }
    const pager::Rect frame = _document.session.viewport().layout().pageFrame(quad.pageIndex);
    const pager::Point a = pager::UserToPageView(*page, quad.quad.v[0]);
    const pager::Point b = pager::UserToPageView(*page, quad.quad.v[1]);
    return NSMakePoint(frame.x + (a.x + b.x) * 0.5, frame.y + (a.y + b.y) * 0.5);
}

- (BOOL)prepareLookUpAt:(pager::Point)document {
    if (_document == nil || _textEditor != nil || !ToolAllowsTextLookUp(_document.session.tool())) {
        return NO;
    }
    if ([_controller noteAt:document] != nullptr || _document.session.viewport().layout().pageAt(document) < 0) {
        return NO;
    }
    [_controller cancelGesture];
    if (_pressedOnSelection && !_pressedSelection.text.empty()) {
        _document.session.setSelection(_pressedSelection);
        [_controller updateSelectionLayers];
        return YES;
    }
    if (TrimmedSelectionText(_document.session).length > 0 &&
        SelectionContainsDocumentPoint(_document.session, document)) {
        return YES;
    }
    [_controller selectTextFrom:document to:document word:YES];
    return TrimmedSelectionText(_document.session).length > 0;
}

- (void)showDefinitionForCurrentSelectionAt:(NSPoint)origin {
    if (_document == nil) {
        return;
    }
    NSString *text = TrimmedSelectionText(_document.session);
    if (text.length == 0) {
        return;
    }
    NSAttributedString *string =
        [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:16]}];
    [self showDefinitionForAttributedString:string atPoint:origin];
}

- (void)lookUpAtEvent:(NSEvent *)event {
    if (_forceClickLookUpShown) {
        return;
    }
    if (![self prepareLookUpAt:[self documentPoint:event]]) {
        return;
    }
    _forceClickLookUpShown = YES;
    [self showDefinitionForCurrentSelectionAt:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)quickLookWithEvent:(NSEvent *)event {
    [self lookUpAtEvent:event];
}

- (void)pressureChangeWithEvent:(NSEvent *)event {
    [super pressureChangeWithEvent:event];
    if (event.stage >= 2) {
        [self lookUpAtEvent:event];
    }
}

- (void)lookUpSelection:(id)sender {
    [self showDefinitionForCurrentSelectionAt:[self selectionBaselineInView]];
}

- (void)searchSelectionOnGoogle:(id)sender {
    if (_document == nil) {
        return;
    }
    NSURL *url = GoogleSearchURL(TrimmedSelectionText(_document.session));
    if (url != nil) {
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking != nil) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingCursorUpdate |
                                                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (NSCursor *)cursorAt:(pager::Point)point {
    if (_document == nil) {
        return NSCursor.arrowCursor;
    }
    pager::DocumentSession &session = _document.session;
    if (session.viewport().layout().pageAt(point) < 0) {
        return NSCursor.arrowCursor;
    }
    const NSInteger handle = [_controller handleAt:point];
    if (handle >= 0 && handle < 4) {
        return NSCursor.crosshairCursor;
    }
    switch (session.tool()) {
        case pager::Tool::Scroll:
        case pager::Tool::SelectNote:
            if (handle == 8 || [_controller noteAt:point] != nullptr) {
                return NSCursor.openHandCursor;
            }
            return NSCursor.IBeamCursor;
        case pager::Tool::SelectText:
        case pager::Tool::Highlight:
        case pager::Tool::Underline:
        case pager::Tool::StrikeOut:
        case pager::Tool::FreeText:
            return NSCursor.IBeamCursor;
        default:
            return NSCursor.crosshairCursor;
    }
}

- (void)updateCursorFor:(NSEvent *)event {
    if (_controller.gesture == PagerGestureHandle) {
        [NSCursor.closedHandCursor set];
        return;
    }
    [[self cursorAt:[self documentPoint:event]] set];
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateCursorFor:event];
}

- (void)cursorUpdate:(NSEvent *)event {
    [self updateCursorFor:event];
}

#pragma mark - Context menu

- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (_document == nil) {
        return nil;
    }
    pager::DocumentSession &session = _document.session;
    const pager::Point point = [self documentPoint:event];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    if (const pager::Annotation *hit = [_controller noteAt:point]) {
        if (!(hit->id == session.selectedNote())) {
            session.setSelectedNote(hit->id);
            [_controller updateChrome];
            [self.delegate canvasViewSelectionChanged:self];
        }
        const pager::Annotation note = *hit;
        if (note.kind == pager::AnnotationKind::FreeText) {
            [menu addItemWithTitle:@"Edit Text" action:@selector(editSelectedNote) keyEquivalent:@""].target = self;
            [menu addItem:NSMenuItem.separatorItem];
        }
        const pager::Tool styleTool = pager::ToolForAnnotation(note);
        NSMenuItem *colorItem = [menu addItemWithTitle:@"Color" action:nil keyEquivalent:@""];
        NSMenu *colors = [[NSMenu alloc] initWithTitle:@"Color"];
        for (const pager::Color color : pager::PaletteColors(styleTool)) {
            NSMenuItem *item = [colors addItemWithTitle:@"" action:@selector(applyContextColor:) keyEquivalent:@""];
            item.target = self;
            item.image = Swatch(color);
            item.representedObject = @[@(color.r), @(color.g), @(color.b), @(color.a)];
            item.state = pager::SameHue(color, note.color) ? NSControlStateValueOn : NSControlStateValueOff;
        }
        colorItem.submenu = colors;
        const std::vector<float> sizes = pager::PaletteSizes(styleTool);
        if (!sizes.empty()) {
            NSMenuItem *sizeItem = [menu addItemWithTitle:@"Size" action:nil keyEquivalent:@""];
            NSMenu *sizeMenu = [[NSMenu alloc] initWithTitle:@"Size"];
            const float current = note.kind == pager::AnnotationKind::FreeText ? note.fontSize : note.lineWidth;
            for (std::size_t index = 0; index < sizes.size(); ++index) {
                NSString *title = note.kind == pager::AnnotationKind::FreeText
                                      ? [NSString stringWithFormat:@"%.0f pt", sizes[index]]
                                      : @[@"Small", @"Medium", @"Large", @"Extra Large"][std::min<std::size_t>(index, 3)];
                NSMenuItem *item = [sizeMenu addItemWithTitle:title action:@selector(applyContextSize:) keyEquivalent:@""];
                item.target = self;
                item.representedObject = @(sizes[index]);
                item.state = std::fabs(sizes[index] - current) < 0.26f ? NSControlStateValueOn : NSControlStateValueOff;
            }
            sizeItem.submenu = sizeMenu;
        }
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""].target = self;
        return menu;
    }
    if (session.selection().quads.empty()) {
        [_controller selectTextFrom:point to:point word:YES];
    }
    const BOOL hasText = !session.selection().quads.empty();
    NSMenuItem *copy = [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    copy.target = self;
    if (hasText) {
        NSMenuItem *lookUp = [menu addItemWithTitle:@"Look Up" action:@selector(lookUpSelection:) keyEquivalent:@""];
        lookUp.target = self;
        NSMenuItem *google = [menu addItemWithTitle:GoogleSearchTitle(TrimmedSelectionText(session))
                                             action:@selector(searchSelectionOnGoogle:)
                                      keyEquivalent:@""];
        google.target = self;
    }
    [menu addItem:NSMenuItem.separatorItem];
    const struct {
        NSString *title;
        SEL action;
    } markups[] = {
        {@"Highlight", @selector(highlightSelection:)},
        {@"Underline", @selector(underlineSelection:)},
        {@"Strikethrough", @selector(strikeSelection:)},
    };
    for (const auto &markup : markups) {
        NSMenuItem *item = [menu addItemWithTitle:markup.title action:hasText ? markup.action : nil keyEquivalent:@""];
        item.target = self;
    }
    if (!hasText) {
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@""];
        [menu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@""];
        [menu addItemWithTitle:@"Zoom to Fit Width" action:@selector(zoomToFitWidth:) keyEquivalent:@""];
    }
    return menu;
}

- (void)applyContextColor:(NSMenuItem *)item {
    NSArray<NSNumber *> *rgba = item.representedObject;
    [_controller applyColorToSelection:pager::Color{rgba[0].floatValue, rgba[1].floatValue, rgba[2].floatValue,
                                                    rgba[3].floatValue}];
}

- (void)applyContextSize:(NSMenuItem *)item {
    [_controller applySizeToSelection:[item.representedObject floatValue]];
}

#pragma mark - Edit actions

- (void)copy:(id)sender {
    if (_document == nil) {
        return;
    }
    const pager::DocumentSession &session = _document.session;
    std::string text = session.selection().text;
    if (text.empty()) {
        if (const pager::Annotation *note = session.selectedAnnotation()) {
            text = note->contents;
        }
    }
    if (text.empty()) {
        return;
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:@(text.c_str()) ?: @"" forType:NSPasteboardTypeString];
}

- (void)delete:(id)sender {
    [_controller deleteSelectedNote];
}

- (void)highlightSelection:(id)sender {
    [_controller applyMarkupKind:pager::AnnotationKind::Highlight];
}

- (void)underlineSelection:(id)sender {
    [_controller applyMarkupKind:pager::AnnotationKind::Underline];
}

- (void)strikeSelection:(id)sender {
    [_controller applyMarkupKind:pager::AnnotationKind::StrikeOut];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (_document == nil) {
        return NO;
    }
    const pager::DocumentSession &session = _document.session;
    const SEL action = item.action;
    if (action == @selector(copy:)) {
        const pager::Annotation *note = session.selectedAnnotation();
        return !session.selection().text.empty() || (note != nullptr && !note->contents.empty());
    }
    if (action == @selector(delete:)) {
        return session.selectedNote().value != 0;
    }
    if (action == @selector(highlightSelection:) || action == @selector(underlineSelection:) ||
        action == @selector(strikeSelection:)) {
        return !session.selection().quads.empty();
    }
    if (action == @selector(lookUpSelection:) || action == @selector(searchSelectionOnGoogle:)) {
        return TrimmedSelectionText(session).length > 0;
    }
    if (action == @selector(editSelectedNote)) {
        const pager::Annotation *note = session.selectedAnnotation();
        return note != nullptr && note->kind == pager::AnnotationKind::FreeText;
    }
    return YES;
}

#pragma mark - Keyboard

- (void)nudgeSelectionBy:(NSPoint)delta {
    const pager::Annotation *selected = _document.session.selectedAnnotation();
    const pager::PageGeometry *page = selected == nullptr ? nullptr : _document.session.viewport().geometry(selected->pageIndex);
    if (page == nullptr || selected->kind == pager::AnnotationKind::Highlight ||
        selected->kind == pager::AnnotationKind::Underline || selected->kind == pager::AnnotationKind::StrikeOut) {
        return;
    }
    const pager::Point origin = pager::PageViewToUser(*page, pager::Point{0, 0});
    const pager::Point moved = pager::PageViewToUser(*page, pager::Point{delta.x, delta.y});
    const double dx = moved.x - origin.x;
    const double dy = moved.y - origin.y;
    const bool changed = _document.session.notes().update(selected->id, [&](pager::Annotation &note) {
        note.bounds.x += dx;
        note.bounds.y += dy;
        note.lineStart.x += dx;
        note.lineStart.y += dy;
        note.lineEnd.x += dx;
        note.lineEnd.y += dy;
        for (pager::InkSample &sample : note.samples) {
            sample.x += dx;
            sample.y += dy;
        }
    });
    if (changed) {
        [_document saveNotes];
        [_controller contentDidChange];
        [self.delegate canvasViewNotesChanged:self];
    }
}

- (void)keyDown:(NSEvent *)event {
    if (_document == nil) {
        [super keyDown:event];
        return;
    }
    pager::DocumentSession &session = _document.session;
    const NSEventModifierFlags modifiers =
        event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption);
    NSString *characters = event.charactersIgnoringModifiers;
    const unichar key = characters.length > 0 ? [characters characterAtIndex:0] : 0;
    if (modifiers == 0 && (key == NSDeleteCharacter || key == NSBackspaceCharacter || key == NSDeleteFunctionKey) &&
        session.selectedNote().value != 0) {
        [_controller deleteSelectedNote];
        return;
    }
    if (key == 0x1b) {
        if (_controller.gesture != PagerGestureNone) {
            [_controller cancelGesture];
        } else if (![_controller clearTextSelection]) {
            if (session.selectedNote().value != 0) {
                session.setSelectedNote({});
                [_controller updateChrome];
                [self.delegate canvasViewSelectionChanged:self];
            } else if (session.tool() != pager::Tool::Scroll) {
                [self.delegate canvasView:self selectTool:pager::Tool::Scroll];
            } else if ((self.window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
                [self.window toggleFullScreen:nil];
            }
        }
        return;
    }
    if (modifiers == 0 && session.selectedNote().value != 0 &&
        (key == NSLeftArrowFunctionKey || key == NSRightArrowFunctionKey || key == NSUpArrowFunctionKey ||
         key == NSDownArrowFunctionKey)) {
        const CGFloat step = (event.modifierFlags & NSEventModifierFlagShift) ? 10 : 1;
        NSPoint delta = NSZeroPoint;
        if (key == NSLeftArrowFunctionKey) {
            delta.x = -step;
        } else if (key == NSRightArrowFunctionKey) {
            delta.x = step;
        } else if (key == NSUpArrowFunctionKey) {
            delta.y = -step;
        } else {
            delta.y = step;
        }
        [self nudgeSelectionBy:delta];
        return;
    }
    if (modifiers == 0 && characters.length == 1) {
        // Single-key tool shortcuts, only while the page has focus (never while typing).
        static const struct {
            unichar key;
            pager::Tool tool;
        } shortcuts[] = {
            {'v', pager::Tool::Scroll}, {'h', pager::Tool::Highlight}, {'u', pager::Tool::Underline},
            {'k', pager::Tool::StrikeOut}, {'p', pager::Tool::Pen}, {'m', pager::Tool::Marker},
            {'e', pager::Tool::Eraser}, {'r', pager::Tool::Square}, {'o', pager::Tool::Circle},
            {'l', pager::Tool::Line}, {'t', pager::Tool::FreeText},
        };
        const unichar lower = static_cast<unichar>(std::tolower(key));
        for (const auto &shortcut : shortcuts) {
            if (shortcut.key == lower) {
                [self.delegate canvasView:self selectTool:shortcut.tool];
                return;
            }
        }
    }
    [super keyDown:event];
}

@end
