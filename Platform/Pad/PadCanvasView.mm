#import "PadCanvasView.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

// UIKit host for PagerCanvasController: touches and Apple Pencil input, the live view, the
// in-place text editor, long-press text selection and the edit menu. Rendering and the
// annotation gestures themselves live in the shared controller.

@class PadCanvasView;

@interface PadCanvasView () <PagerCanvasHost, UITextViewDelegate, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate>
- (void)drawLiveInContext:(CGContextRef)context rect:(CGRect)rect;
- (void)lookUpCurrentSelection;
- (void)searchSelectionOnGoogle;
@end

@interface PadLiveView : UIView
@property(nonatomic, weak) PadCanvasView *canvas;
@end

@implementation PadLiveView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.clearsContextBeforeDrawing = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.layer.actions = @{@"contents" : NSNull.null, @"bounds" : NSNull.null, @"position" : NSNull.null};
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    [self.canvas drawLiveInContext:UIGraphicsGetCurrentContext() rect:rect];
}

@end

namespace {

constexpr double kMaxLivePixels = 14.0e6;

UIColor *NoteTextColor(const pager::Annotation &note) {
    const CGFloat alpha = note.color.a == 0 ? 1 : note.color.a;
    return [UIColor colorWithRed:note.color.r green:note.color.g blue:note.color.b alpha:alpha];
}

UIFont *NoteTextFont(const pager::Annotation &note) {
    const CGFloat size = std::max(8.0f, note.fontSize > 0 ? note.fontSize : 14);
    return [UIFont fontWithName:@"Helvetica" size:size] ?: [UIFont systemFontOfSize:size];
}

}  // namespace

@implementation PadCanvasView {
    __weak PadDocument *_document;
    PagerCanvasController *_controller;
    UIView *_pagesHost;
    UIView *_chromeHost;
    PadLiveView *_liveView;
    UITouch *_activeTouch;
    BOOL _panSuspended;
    BOOL _panWasEnabled;
    std::unordered_map<NSInteger, std::size_t> _estimatedSamples;
    UITextView *_textEditor;
    UILongPressGestureRecognizer *_textPress;
    UITapGestureRecognizer *_dismissSelectionTap;
    UIEditMenuInteraction *_editMenu;
    pager::Point _textPressStart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
        NSDictionary *noActions = @{@"sublayers" : NSNull.null, @"bounds" : NSNull.null, @"position" : NSNull.null};
        _pagesHost = [[UIView alloc] initWithFrame:self.bounds];
        _pagesHost.userInteractionEnabled = NO;
        _pagesHost.backgroundColor = UIColor.clearColor;
        _pagesHost.layer.actions = noActions;
        [self addSubview:_pagesHost];
        _chromeHost = [[UIView alloc] initWithFrame:self.bounds];
        _chromeHost.userInteractionEnabled = NO;
        _chromeHost.backgroundColor = UIColor.clearColor;
        _chromeHost.layer.actions = noActions;
        [self addSubview:_chromeHost];
        _liveView = [[PadLiveView alloc] initWithFrame:CGRectZero];
        _liveView.canvas = self;
        _liveView.hidden = YES;
        [self addSubview:_liveView];
        _controller = [[PagerCanvasController alloc] initWithPagesLayer:_pagesHost.layer
                                                            chromeLayer:_chromeHost.layer
                                                                   host:self];

        _textPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleTextPress:)];
        _textPress.minimumPressDuration = 0.42;
        _textPress.allowableMovement = 14;
        _textPress.cancelsTouchesInView = YES;
        _textPress.delegate = self;
        [self addGestureRecognizer:_textPress];
        _dismissSelectionTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDismissSelectionTap:)];
        _dismissSelectionTap.cancelsTouchesInView = YES;
        _dismissSelectionTap.delegate = self;
        [self addGestureRecognizer:_dismissSelectionTap];
        if (@available(iOS 16.0, *)) {
            _editMenu = [[UIEditMenuInteraction alloc] initWithDelegate:self];
        }
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    // No full detach here: it schedules blocks that would take weak references to self.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_panSuspended) {
        [self hostScrollView].panGestureRecognizer.enabled = _panWasEnabled;
    }
    [_controller shutdown];
}

- (PagerCanvasController *)controller {
    return _controller;
}

#pragma mark - Document lifetime

- (void)attachToDocument:(PadDocument *)document {
    [self detachViewport];
    _document = document;
    [_controller attachDocument:document];
    [self syncFrameAndTiles];
}

- (void)detachViewport {
    _activeTouch = nil;
    [_controller detach];
    _document = nil;
    [self setScrollPanSuspended:NO];
}

- (UIScrollView *)hostScrollView {
    UIView *view = self.superview;
    while (view != nil) {
        if ([view isKindOfClass:[UIScrollView class]]) {
            return (UIScrollView *)view;
        }
        view = view.superview;
    }
    return nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window != nil && _document != nil) {
        [self updateVisibleRect];
    }
}

- (void)syncFrameAndTiles {
    if (_document == nil) {
        return;
    }
    const pager::Size content = _document.session.viewport().layout().contentSize();
    const CGRect frame = CGRectMake(0, 0, std::max(1.0, content.width), std::max(1.0, content.height));
    self.frame = frame;
    if (self.superview != nil && ![self.superview isKindOfClass:[UIScrollView class]]) {
        self.superview.frame = frame;
    }
    _pagesHost.frame = self.bounds;
    _chromeHost.frame = self.bounds;
    [self updateVisibleRect];
}

- (void)followVisibleRect {
    [_controller visibleRectDidChangeWhileZooming];
}

- (void)updateVisibleRect {
    [_controller visibleRectDidChange];
}

- (void)updateOverlay {
    [self syncTextEditorStyle];
}

- (void)setNeedsDisplay {
    [_controller contentDidChange];
}

- (void)setNeedsDisplayInRect:(CGRect)rect {
    [_controller contentDidChange];
}

- (void)annotationsDidChange {
    [_controller contentDidChange];
}

- (void)handleMemoryWarning {
    [_controller handleMemoryWarning];
}

- (void)clearTextSelection {
    if ([_controller clearTextSelection]) {
        if (@available(iOS 16.0, *)) {
            [_editMenu dismissMenu];
        }
    }
}

- (void)applyMarkupKind:(pager::AnnotationKind)kind {
    [_controller applyMarkupKind:kind];
}

- (NSString *)selectedText {
    if (_document == nil || _document.session.selection().text.empty()) {
        return @"";
    }
    return [@(_document.session.selection().text.c_str())
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)searchSelectionOnGoogle {
    NSString *query = [self selectedText];
    if (query.length == 0) {
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.google.com/search"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:query]];
    NSURL *url = components.URL;
    if (url != nil) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

- (void)lookUpCurrentSelection {
    NSString *query = [self selectedText];
    if (query.length == 0) {
        return;
    }
    UIViewController *host = nil;
    for (UIResponder *responder = self; responder != nil; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            host = (UIViewController *)responder;
            break;
        }
    }
    if (host == nil) {
        return;
    }
    UIReferenceLibraryViewController *lookup = [[UIReferenceLibraryViewController alloc] initWithTerm:query];
    lookup.modalPresentationStyle = UIModalPresentationPageSheet;
    [host presentViewController:lookup animated:YES completion:nil];
}

#pragma mark - PagerCanvasHost

- (CGRect)canvasVisibleDocumentRect {
    UIScrollView *scroll = [self hostScrollView];
    return scroll == nil ? self.bounds : [self convertRect:scroll.bounds fromView:scroll];
}

- (CGRect)canvasBounds {
    return self.bounds;
}

- (double)canvasZoomScale {
    UIScrollView *scroll = [self hostScrollView];
    return scroll == nil ? 1 : std::max(0.05, static_cast<double>(scroll.zoomScale));
}

- (CGFloat)canvasScreenScale {
    return self.window.windowScene.screen.scale ?: UIScreen.mainScreen.scale;
}

- (void)canvasLiveContentChanged {
    if (![_controller liveHasContent]) {
        if (!_liveView.hidden) {
            _liveView.hidden = YES;
            _liveView.layer.contents = nil;
        }
        return;
    }
    if (_controller.zooming && !_liveView.hidden) {
        return;
    }
    const CGRect visible = CGRectIntersection([self canvasVisibleDocumentRect], self.bounds);
    if (CGRectIsEmpty(visible)) {
        return;
    }
    const CGRect frame = CGRectIntegral(visible);
    double scale = [self canvasScreenScale] * [self canvasZoomScale];
    const double pixels = frame.size.width * frame.size.height * scale * scale;
    if (pixels > kMaxLivePixels) {
        scale *= std::sqrt(kMaxLivePixels / pixels);
    }
    const BOOL moved = !CGRectEqualToRect(frame, _liveView.frame) || std::fabs(_liveView.contentScaleFactor - scale) > 1e-3;
    if (moved || _liveView.hidden) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _liveView.frame = frame;
        _liveView.contentScaleFactor = scale;
        _liveView.hidden = NO;
        [CATransaction commit];
        [_liveView setNeedsDisplay];
    }
}

- (void)canvasInvalidateLiveRect:(CGRect)documentRect {
    if (_liveView.hidden) {
        return;
    }
    const CGRect frame = _liveView.frame;
    [_liveView setNeedsDisplayInRect:CGRectIntegral(CGRectOffset(documentRect, -frame.origin.x, -frame.origin.y))];
}

- (void)drawLiveInContext:(CGContextRef)context rect:(CGRect)rect {
    const CGPoint origin = _liveView.frame.origin;
    CGContextTranslateCTM(context, -origin.x, -origin.y);
    [_controller drawLiveInContext:context documentRect:CGRectOffset(rect, origin.x, origin.y)];
}

// While a Pencil stroke is in flight, the resting palm must not pan the scroll view.
- (void)canvasSetPanSuspended:(BOOL)suspended {
    [self setScrollPanSuspended:suspended];
}

- (void)setScrollPanSuspended:(BOOL)suspended {
    UIScrollView *scroll = [self hostScrollView];
    if (scroll == nil) {
        return;
    }
    if (suspended) {
        if (_panSuspended) {
            return;
        }
        _panSuspended = YES;
        _panWasEnabled = scroll.panGestureRecognizer.enabled;
        scroll.panGestureRecognizer.enabled = NO;
    } else {
        if (!_panSuspended) {
            return;
        }
        _panSuspended = NO;
        scroll.panGestureRecognizer.enabled = _panWasEnabled;
    }
}

- (void)canvasEditNote:(pager::AnnotationId)identifier isNew:(BOOL)isNew {
    [self endTextEditing];
    const pager::Annotation *note = _document == nil ? nullptr : _document.session.notes().find(identifier);
    if (note == nullptr || note->kind != pager::AnnotationKind::FreeText) {
        return;
    }
    _textEditor = [[UITextView alloc] initWithFrame:CGRectInset([_controller documentRectForNote:*note], 4, 3)];
    _textEditor.backgroundColor = UIColor.clearColor;
    _textEditor.opaque = NO;
    _textEditor.text = @(note->contents.c_str()) ?: @"";
    _textEditor.delegate = self;
    _textEditor.textContainerInset = UIEdgeInsetsMake(2, 2, 2, 2);
    _textEditor.textContainer.lineFragmentPadding = 0;
    _textEditor.clipsToBounds = YES;
    [self applyEditorStyleFromNote:*note];
    [self addSubview:_textEditor];
    [_controller beginEditingNote:identifier isNew:isNew];
    [_textEditor becomeFirstResponder];
}

- (void)canvasEndTextEditing {
    [self endTextEditing];
}

- (void)canvasSyncTextEditor {
    [self syncTextEditorStyle];
}

- (void)canvasOpenLink:(const pager::LinkHit &)link {
    if (link.hasDestination) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerScrollToPage" object:_document userInfo:@{
            @"page" : @(link.pageIndex),
            @"x" : @(link.point.x),
            @"y" : @(link.point.y),
        }];
    } else if (!link.url.empty()) {
        NSURL *url = [NSURL URLWithString:@(link.url.c_str()) ?: @""];
        if (url != nil) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }
    }
}

- (void)canvasSelectTool:(pager::Tool)tool {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerSelectTool"
                                                        object:_document
                                                      userInfo:@{@"tool" : @(static_cast<NSInteger>(tool))}];
}

- (void)canvasBackgroundTapped {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerToggleChrome" object:_document];
}

- (void)canvasNotesChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerNotesChanged" object:_document];
}

- (void)canvasSelectionChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerSelectionChanged" object:_document];
}

#pragma mark - Text editor

- (void)applyEditorStyleFromNote:(const pager::Annotation &)note {
    if (_textEditor == nil) {
        return;
    }
    UIColor *color = NoteTextColor(note);
    UIFont *font = NoteTextFont(note);
    _textEditor.font = font;
    _textEditor.textColor = color;
    _textEditor.tintColor = color;
    _textEditor.typingAttributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : color,
    };
}

- (void)syncTextEditorStyle {
    const pager::AnnotationId editing = _controller.editingNoteId;
    if (_document == nil || _textEditor == nil || editing.value == 0) {
        return;
    }
    const pager::Annotation *note = _document.session.notes().find(editing);
    if (note == nullptr) {
        [self endTextEditing];
        return;
    }
    _textEditor.frame = CGRectInset([_controller documentRectForNote:*note], 4, 3);
    [self applyEditorStyleFromNote:*note];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView == _textEditor) {
        [_controller editingTextDidChange:textView.text.UTF8String ?: ""];
    }
}

- (void)endTextEditing {
    if (_textEditor == nil) {
        return;
    }
    UITextView *editor = _textEditor;
    _textEditor = nil;
    [editor resignFirstResponder];
    [editor removeFromSuperview];
    [_controller finishEditingWithText:editor.text.UTF8String ?: ""];
}

- (BOOL)textViewShouldEndEditing:(UITextView *)textView {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_textEditor == textView) {
            [self endTextEditing];
        }
    });
    return YES;
}

#pragma mark - Text selection gestures and edit menu

- (BOOL)markupToolIsActive {
    if (_document == nil) {
        return NO;
    }
    const pager::Tool tool = _document.session.tool();
    return tool == pager::Tool::Highlight || tool == pager::Tool::Underline || tool == pager::Tool::StrikeOut;
}

- (BOOL)touchIsInEditor:(UITouch *)touch {
    return _textEditor != nil && touch.view != nil && [touch.view isDescendantOfView:_textEditor];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == _dismissSelectionTap) {
        return _document != nil && !_document.session.selection().quads.empty() && ![self markupToolIsActive];
    }
    if (gesture == _textPress) {
        return ![self markupToolIsActive];
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if ([self touchIsInEditor:touch]) {
        return NO;
    }
    if (gesture == _dismissSelectionTap) {
        return _document != nil && !_document.session.selection().quads.empty() && ![self markupToolIsActive];
    }
    if (gesture != _textPress || _document == nil) {
        return YES;
    }
    if ([self markupToolIsActive]) {
        return NO;
    }
    if (touch.type == UITouchTypePencil) {
        return _document.session.tool() == pager::Tool::Scroll;
    }
    return YES;
}

- (void)handleDismissSelectionTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) {
        [self clearTextSelection];
    }
}

- (void)handleTextPress:(UILongPressGestureRecognizer *)press {
    if (_document == nil) {
        return;
    }
    const CGPoint location = [press locationInView:self];
    if (!std::isfinite(location.x) || !std::isfinite(location.y)) {
        return;
    }
    const pager::Point point{location.x, location.y};
    if (press.state == UIGestureRecognizerStateBegan) {
        [self endTextEditing];
        [_controller cancelGesture];
        _activeTouch = nil;
        _textPressStart = point;
        [_controller selectTextFrom:point to:point word:YES];
        return;
    }
    if (press.state == UIGestureRecognizerStateChanged) {
        [_controller selectTextFrom:_textPressStart to:point word:NO];
        return;
    }
    if (press.state != UIGestureRecognizerStateEnded || _document.session.selection().quads.empty()) {
        return;
    }
    if (@available(iOS 16.0, *)) {
        UIView *host = [self hostScrollView] ?: self;
        const CGPoint menuPoint = [press locationInView:host];
        if (!std::isfinite(menuPoint.x) || !std::isfinite(menuPoint.y) || self.window == nil) {
            return;
        }
        if (_editMenu.view != host) {
            [_editMenu.view removeInteraction:_editMenu];
            [host addInteraction:_editMenu];
        }
        [_editMenu presentEditMenuWithConfiguration:[UIEditMenuConfiguration configurationWithIdentifier:@"pager.text"
                                                                                             sourcePoint:menuPoint]];
    }
}

- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction
           menuForConfiguration:(UIEditMenuConfiguration *)configuration
               suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions {
    if (_document == nil || _document.session.selection().quads.empty()) {
        return nil;
    }
    __weak PadCanvasView *weakSelf = self;
    UIAction *copy = [UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                                      handler:^(__unused UIAction *action) {
                                          PadCanvasView *self_ = weakSelf;
                                          if (self_ == nil || self_->_document == nil) {
                                              return;
                                          }
                                          UIPasteboard.generalPasteboard.string =
                                              @(self_->_document.session.selection().text.c_str()) ?: @"";
                                      }];
    UIAction *lookUp = [UIAction actionWithTitle:@"Look Up" image:[UIImage systemImageNamed:@"book"] identifier:nil
                                        handler:^(__unused UIAction *action) {
                                            [weakSelf lookUpCurrentSelection];
                                        }];
    UIAction *google = [UIAction actionWithTitle:@"Search with Google"
                                          image:[UIImage systemImageNamed:@"magnifyingglass"]
                                     identifier:nil
                                        handler:^(__unused UIAction *action) {
                                            [weakSelf searchSelectionOnGoogle];
                                        }];
    UIAction *highlight = [UIAction actionWithTitle:@"Highlight" image:[UIImage systemImageNamed:@"highlighter"] identifier:nil
                                           handler:^(__unused UIAction *action) {
                                               [weakSelf applyMarkupKind:pager::AnnotationKind::Highlight];
                                           }];
    UIAction *underline = [UIAction actionWithTitle:@"Underline" image:[UIImage systemImageNamed:@"underline"] identifier:nil
                                           handler:^(__unused UIAction *action) {
                                               [weakSelf applyMarkupKind:pager::AnnotationKind::Underline];
                                           }];
    UIAction *strike = [UIAction actionWithTitle:@"Strike" image:[UIImage systemImageNamed:@"strikethrough"] identifier:nil
                                        handler:^(__unused UIAction *action) {
                                            [weakSelf applyMarkupKind:pager::AnnotationKind::StrikeOut];
                                        }];
    return [UIMenu menuWithChildren:@[copy, lookUp, google, highlight, underline, strike]];
}

#pragma mark - Touches

- (BOOL)drawsWithPencil:(UITouch *)touch {
    if (touch.type == UITouchTypePencil) {
        return YES;
    }
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return NO;
#endif
}

- (BOOL)toolNeedsPencil:(pager::Tool)tool {
    if (tool == pager::Tool::Scroll || tool == pager::Tool::SelectNote || tool == pager::Tool::SelectText ||
        tool == pager::Tool::Highlight || tool == pager::Tool::Underline || tool == pager::Tool::StrikeOut) {
        return NO;
    }
#if TARGET_OS_SIMULATOR
    return tool == pager::Tool::Pen || tool == pager::Tool::Marker || tool == pager::Tool::Eraser;
#else
    return YES;
#endif
}

- (UITouch *)preferredTouchIn:(NSSet<UITouch *> *)touches forTool:(pager::Tool)tool {
    UITouch *pencil = nil;
    UITouch *other = nil;
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypePencil) {
            pencil = touch;
            break;
        }
        if (other == nil) {
            other = touch;
        }
    }
    if ([self toolNeedsPencil:tool]) {
#if TARGET_OS_SIMULATOR
        return pencil ?: other;
#else
        return pencil;
#endif
    }
    return pencil ?: other;
}

- (UITouch *)trackedTouchIn:(NSSet<UITouch *> *)touches {
    return _activeTouch != nil && [touches containsObject:_activeTouch] ? _activeTouch : nil;
}

- (pager::Point)pointOf:(UITouch *)touch {
    const CGPoint location = [touch preciseLocationInView:self];
    return pager::Point{location.x, location.y};
}

- (pager::InkSample)sampleFromTouch:(UITouch *)touch predicted:(BOOL)predicted {
    return [_controller inkSampleAt:[self pointOf:touch]
                              force:static_cast<float>(touch.force)
                           altitude:static_cast<float>(touch.altitudeAngle)
                            azimuth:static_cast<float>([touch azimuthAngleInView:self])
                               time:touch.timestamp
                          predicted:predicted];
}

- (void)recordEstimations:(NSArray<UITouch *> *)touches indices:(const std::vector<std::size_t> &)indices {
    for (NSUInteger index = 0; index < touches.count && index < indices.size(); ++index) {
        UITouch *touch = touches[index];
        if (touch.estimationUpdateIndex != nil && touch.estimatedPropertiesExpectingUpdates != 0) {
            _estimatedSamples[touch.estimationUpdateIndex.integerValue] = indices[index];
        }
    }
}

- (void)feedInkFor:(UITouch *)touch event:(UIEvent *)event begin:(BOOL)begin {
    NSArray<UITouch *> *coalesced = [event coalescedTouchesForTouch:touch];
    if (coalesced.count == 0) {
        coalesced = @[touch];
    }
    std::vector<pager::InkSample> samples;
    samples.reserve(coalesced.count);
    for (UITouch *item in coalesced) {
        samples.push_back([self sampleFromTouch:item predicted:NO]);
    }
    std::vector<pager::InkSample> predicted;
    for (UITouch *item in [event predictedTouchesForTouch:touch]) {
        predicted.push_back([self sampleFromTouch:item predicted:YES]);
    }
    const std::vector<std::size_t> indices =
        begin ? [_controller beginInk:samples predicted:predicted] : [_controller appendInk:samples predicted:predicted];
    [self recordEstimations:coalesced indices:indices];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_document == nil || _activeTouch != nil) {
        return;
    }
    const pager::Tool tool = _document.session.tool();
    UITouch *touch = [self preferredTouchIn:touches forTool:tool];
    if (_textEditor != nil) {
        // Any touch outside the box (finger included) finishes the text.
        touch = touches.anyObject;
        if ([self touchIsInEditor:touch]) {
            return;
        }
    } else if (touch == nil || ([self toolNeedsPencil:tool] && ![self drawsWithPencil:touch])) {
        return;
    }
    const PagerGestureKind gesture = [_controller beginGestureAt:[self pointOf:touch] clickCount:touch.tapCount];
    if (gesture == PagerGestureNone) {
        return;
    }
    _activeTouch = touch;
    if (gesture == PagerGestureInk) {
        _estimatedSamples.clear();
        [self feedInkFor:touch event:event begin:YES];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // Only the touch that started the gesture drives it; a resting palm or second finger
    // must not hijack a selection or stroke.
    UITouch *touch = [self trackedTouchIn:touches];
    if (touch == nil) {
        return;
    }
    switch (_controller.gesture) {
        case PagerGestureInk:
            if ([self drawsWithPencil:touch]) {
                [self feedInkFor:touch event:event begin:NO];
            }
            break;
        case PagerGestureEraser:
            for (UITouch *item in [event coalescedTouchesForTouch:touch] ?: @[touch]) {
                [_controller moveGestureTo:[self pointOf:item]];
            }
            break;
        default:
            [_controller moveGestureTo:[self pointOf:touch]];
            break;
    }
}

- (void)touchesEstimatedPropertiesUpdated:(NSSet<UITouch *> *)touches {
    if (_controller.gesture != PagerGestureInk) {
        return;
    }
    for (UITouch *touch in touches) {
        if (touch.estimationUpdateIndex == nil) {
            continue;
        }
        const auto found = _estimatedSamples.find(touch.estimationUpdateIndex.integerValue);
        if (found == _estimatedSamples.end()) {
            continue;
        }
        [_controller updateInkSample:found->second
                               force:static_cast<float>(touch.force)
                            altitude:static_cast<float>(touch.altitudeAngle)
                             azimuth:static_cast<float>([touch azimuthAngleInView:self])];
        if (touch.estimatedPropertiesExpectingUpdates == 0) {
            _estimatedSamples.erase(found);
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [self trackedTouchIn:touches];
    if (touch == nil) {
        return;
    }
    _activeTouch = nil;
    if (_controller.gesture == PagerGestureInk && [self drawsWithPencil:touch]) {
        [self feedInkFor:touch event:event begin:NO];
    }
    _estimatedSamples.clear();
    [_controller endGestureAt:[self pointOf:touch]];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_activeTouch != nil && ![touches containsObject:_activeTouch]) {
        return;
    }
    _activeTouch = nil;
    _estimatedSamples.clear();
    [_controller cancelGesture];
}

@end
