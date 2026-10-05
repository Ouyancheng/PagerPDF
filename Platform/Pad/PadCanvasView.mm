#import "PadCanvasView.h"

#import "OverlayRenderer.h"
#import "TileImage.hpp"
#import "Viewport.hpp"
#import "Zoom.hpp"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Tiled backing store so the canvas can be arbitrarily tall (long documents) without hitting
// layer size limits or allocating a bitmap for the whole document. PDF rasterization already
// happens on the Viewport worker thread, so layer tiles just composite pre-rendered images;
// drawing stays on the main thread (drawsAsynchronously = NO) which keeps all session state
// free of cross-thread data races.
@interface PagerTiledLayer : CATiledLayer
@end

@implementation PagerTiledLayer

// No fade-in: tiles should appear immediately.
+ (CFTimeInterval)fadeDuration {
    return 0;
}

@end

namespace {

struct ImageOwner {
    CGImageRef image = nullptr;
    explicit ImageOwner(CGImageRef owned = nullptr) : image(owned) {}
    ImageOwner(const ImageOwner &) = delete;
    ImageOwner &operator=(const ImageOwner &) = delete;
    ImageOwner(ImageOwner &&other) noexcept : image(other.image) { other.image = nullptr; }
    ImageOwner &operator=(ImageOwner &&other) noexcept {
        if (this != &other) {
            if (image != nullptr) {
                CGImageRelease(image);
            }
            image = other.image;
            other.image = nullptr;
        }
        return *this;
    }
    ~ImageOwner() {
        if (image != nullptr) {
            CGImageRelease(image);
        }
    }
};

struct PadTileClient : pager::TileClient {
    __weak PadCanvasView *view = nil;
    void tileReady(pager::TileImage image) override {
        auto *box = new pager::TileImage(std::move(image));
        __weak PadCanvasView *weakView = view;
        dispatch_async(dispatch_get_main_queue(), ^{
            PadCanvasView *strongView = weakView;
            if (strongView == nil) {
                delete box;
                return;
            }
            [strongView acceptTile:std::move(*box)];
            delete box;
        });
    }
};

pager::InkSample SampleFromTouch(UITouch *touch, UIView *view, PadDocument *document, int page, bool predicted) {
    pager::InkSample sample;
    sample.predicted = predicted;
    sample.force = touch.force;
    sample.altitude = touch.altitudeAngle;
    sample.time = touch.timestamp;
    const pager::PageGeometry *geometry = document.session.viewport().geometry(page);
    if (geometry == nullptr) {
        return sample;
    }
    const CGPoint location = [touch locationInView:view];
    pager::Point pageView = document.session.viewport().layout().documentToPageView(page, pager::Point{location.x, location.y});
    // Clip to the page so a stroke that crosses the page edge rides along the edge instead of
    // landing at nonsense coordinates in the page's user space.
    const pager::Size displayed = pager::DisplayedSize(*geometry);
    pageView.x = std::clamp(pageView.x, 0.0, displayed.width);
    pageView.y = std::clamp(pageView.y, 0.0, displayed.height);
    const pager::Point user = pager::PageViewToUser(*geometry, pageView);
    sample.x = user.x;
    sample.y = user.y;
    sample.azimuth = [touch azimuthAngleInView:view];
    return sample;
}

UIColor *NoteTextColor(const pager::Annotation &note) {
    const CGFloat alpha = note.color.a == 0 ? 1 : note.color.a;
    return [UIColor colorWithRed:note.color.r green:note.color.g blue:note.color.b alpha:alpha];
}

UIFont *NoteTextFont(const pager::Annotation &note) {
    const CGFloat size = std::max(8.0f, note.fontSize > 0 ? note.fontSize : 14);
    return [UIFont fontWithName:@"Helvetica" size:size] ?: [UIFont systemFontOfSize:size];
}

}  // namespace

@interface PadInkOverlayView : UIView
@property(nonatomic, weak) PadDocument *document;
@property(nonatomic, weak) UITextView *editor;
@property(nonatomic, assign) pager::AnnotationId editingNoteId;
@end

@implementation PadInkOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.clearsContextBeforeDrawing = YES;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UITextView *editor = self.editor;
    if (editor == nil || editor.hidden || !editor.userInteractionEnabled) {
        return nil;
    }
    const CGPoint local = [editor convertPoint:point fromView:self];
    if (![editor pointInside:local withEvent:event]) {
        return nil;
    }
    return [editor hitTest:local withEvent:event];
}

- (void)drawRect:(CGRect)rect {
    if (self.document == nil) {
        return;
    }
    // Overlay lives in document space (sibling of the tiled canvas inside the
    // zoom view), so a pinch scales notes with the page — no offset math.
    pager::DrawSessionOverlay(UIGraphicsGetCurrentContext(), rect, self.document.session, true, self.editingNoteId);
}

@end

@interface PadCanvasView () <UITextViewDelegate, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate>
- (void)closeEditorIfNoteGone;
- (void)applyEditorStyleFromNote:(const pager::Annotation &)note;
- (void)updateVisibleRectAndLayerScale:(BOOL)updateLayerScale;
- (BOOL)markupToolIsActive;
@end

@implementation PadCanvasView {
    __weak PadDocument *_document;
    std::unique_ptr<PadTileClient> _client;
    std::mutex _imageMutex;
    std::unordered_map<pager::TileKey, ImageOwner, pager::TileKeyHash> _images;
    pager::Point _dragStart;
    bool _dragging;
    int _dragPage;
    PadInkOverlayView *_inkOverlay;
    UITouch *_activeTouch;
    BOOL _eraseDirty;
    BOOL _panSuspended;
    BOOL _panWasEnabled;
    BOOL _tappedNote;
    BOOL _geometryDirty;
    NSInteger _editHandle;
    UITextView *_textEditor;
    pager::AnnotationId _editingId;
    UILongPressGestureRecognizer *_textPress;
    UITapGestureRecognizer *_dismissSelectionTap;
    UIEditMenuInteraction *_editMenu;
    pager::Point _textPressStart;
}

+ (Class)layerClass {
    return [PagerTiledLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _client = std::make_unique<PadTileClient>();
        _client->view = self;
        self.backgroundColor = [UIColor colorWithWhite:pager::kCanvasGray alpha:1];
        self.opaque = YES;
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
        // Frame stays at layout (PDF-point) size. UIScrollView zooms this view;
        // ScaleToFill would stretch tiles if the bounds ever changed.
        self.contentMode = UIViewContentModeRedraw;
        _dragPage = -1;
        _editHandle = -1;
        _inkOverlay = [[PadInkOverlayView alloc] initWithFrame:CGRectZero];
        PagerTiledLayer *layer = (PagerTiledLayer *)self.layer;
        layer.needsDisplayOnBoundsChange = NO;
        layer.contentsGravity = kCAGravityTopLeft;
        layer.contentsScale = UIScreen.mainScreen.scale;
        layer.backgroundColor = [UIColor colorWithWhite:pager::kCanvasGray alpha:1].CGColor;
        // 256pt tiles == 512px on a 2x display at 1x zoom. contentsScale tracks
        // pinch zoom so higher-density rasters are not downsampled by the layer.
        layer.tileSize = CGSizeMake(256, 256);
        // Extra LODs so a pinch past 2x redraws tiles in a higher-res context
        // without raising the whole layer's contentsScale (that hits the
        // "bogus layer size" limit and drops the draw).
        layer.levelsOfDetail = 4;
        layer.levelsOfDetailBias = 3;
        layer.drawsAsynchronously = NO;
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
    }
    return self;
}

- (void)attachToDocument:(PadDocument *)document {
    {
        std::lock_guard<std::mutex> lock(_imageMutex);
        _images.clear();
    }
    _eraseDirty = NO;
    _document = document;
    _inkOverlay.document = document;
    document.session.viewport().setClient(_client.get());
    const CGFloat scale = self.window.windowScene.screen.scale;
    if (scale > 0) {
        document.session.viewport().setScreenScale(scale);
    }
    [self flushTiledLayer];
    [self syncFrameAndTiles];
}

- (void)detachViewport {
    [self endTextEditing];
    [self setScrollPanSuspended:NO];
    _dragging = false;
    _activeTouch = nil;
    _eraseDirty = NO;
    _inkOverlay.document = nil;
    [_inkOverlay setNeedsDisplay];
    if (_document != nil) {
        _document.session.viewport().setClient(nullptr);
    }
    _document = nil;
}

- (void)dealloc {
    [self detachViewport];
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
    [self layoutInkOverlay];
    [self updateVisibleRect];
}

- (void)flushTiledLayer {
    PagerTiledLayer *tiled = (PagerTiledLayer *)self.layer;
    const CGSize tileSize = tiled.tileSize;
    tiled.contents = nil;
    tiled.tileSize = CGSizeMake(tileSize.width + 1, tileSize.height + 1);
    tiled.tileSize = tileSize;
    [tiled setNeedsDisplay];
}

- (void)syncLayerContentsScale {
    const CGFloat screen = self.window.windowScene.screen.scale ?: UIScreen.mainScreen.scale;
    // Stay at screen scale. Raising contentsScale with pinch (and flushing the
    // tiled layer) discarded every tile and flashed gray. LOD + viewport rasters
    // refine after the gesture; the scroll view supplies the live transform.
    if (std::fabs(self.layer.contentsScale - screen) > 0.001) {
        self.layer.contentsScale = screen;
    }
    // Overlay is one full-document UIView. Matching pinch zoom here allocates
    // width×height×scale² and iOS ignores the draw — selection/ink vanish, or crash.
    if (_inkOverlay != nil && std::fabs(_inkOverlay.layer.contentsScale - screen) > 0.001) {
        _inkOverlay.layer.contentsScale = screen;
        [_inkOverlay setNeedsDisplay];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window != nil) {
        const CGFloat scale = self.window.windowScene.screen.scale ?: UIScreen.mainScreen.scale;
        if (_document != nil) {
            _document.session.viewport().setScreenScale(scale);
        }
        [self syncLayerContentsScale];
        if (_document != nil) {
            [self updateVisibleRect];
        }
    }
}

- (void)followVisibleRect {
    [self updateVisibleRectAndLayerScale:NO];
}

- (void)updateVisibleRect {
    [self updateVisibleRectAndLayerScale:YES];
}

- (void)updateVisibleRectAndLayerScale:(BOOL)updateLayerScale {
    if (_document == nil) {
        return;
    }
    UIScrollView *scroll = [self hostScrollView];
    if (scroll == nil) {
        return;
    }
    if (updateLayerScale) {
        [self syncLayerContentsScale];
    }
    const CGRect visible = [self convertRect:scroll.bounds fromView:scroll];
    _document.session.viewport().setVisibleRect(
        pager::Rect{visible.origin.x, visible.origin.y, visible.size.width, visible.size.height});
    if (_document.source.rasterSource != nullptr) {
        _document.session.viewport().requestVisibleTiles(*_document.source.rasterSource);
    }
    [self pruneTiles];
    [self layoutInkOverlay];
}

- (void)layoutInkOverlay {
    UIView *host = self.superview;
    if (host == nil) {
        return;
    }
    // Sibling of the tiled canvas inside the zoom view — not a CATiledLayer
    // subview (those composite unreliably) and not a scroll-view sibling
    // (those would not pinch with the page).
    if (_inkOverlay.superview != host) {
        [host insertSubview:_inkOverlay aboveSubview:self];
    }
    if (@available(iOS 16.0, *)) {
        UIScrollView *scroll = [self hostScrollView];
        if (_editMenu != nil && scroll != nil && _editMenu.view != scroll) {
            [_editMenu.view removeInteraction:_editMenu];
            [scroll addInteraction:_editMenu];
        }
    }
    if (!CGRectEqualToRect(_inkOverlay.frame, self.frame)) {
        _inkOverlay.frame = self.frame;
    }
}

- (void)updateOverlay {
    [self layoutInkOverlay];
    [self syncTextEditorStyle];
    [_inkOverlay setNeedsDisplay];
}

// Keeps the view-level image store bounded to what is on screen: tiles that scrolled away are
// dropped (the core tile cache still holds them), and slots that are ready in the core cache
// but missing here are copied back in.
- (void)pruneTiles {
    const std::vector<pager::TileSlot> slots = _document.session.viewport().visibleSlots();
    std::unordered_set<pager::TileKey, pager::TileKeyHash> keep;
    keep.reserve(slots.size());
    std::vector<std::pair<pager::TileKey, CGImageRef>> backfill;
    for (const pager::TileSlot &slot : slots) {
        keep.insert(slot.key);
        BOOL have = NO;
        {
            std::lock_guard<std::mutex> lock(_imageMutex);
            have = _images.find(slot.key) != _images.end();
        }
        if (!slot.ready || have) {
            continue;
        }
        pager::TileImage image;
        if (!_document.session.viewport().copyTile(slot.key, &image)) {
            continue;
        }
        CGImageRef cgImage = pager::CreateTileCGImage(image);
        if (cgImage != nullptr) {
            backfill.emplace_back(slot.key, cgImage);
        }
    }
    UIScrollView *scroll = [self hostScrollView];
    const CGRect visible =
        scroll != nil ? [self convertRect:scroll.bounds fromView:scroll] : CGRectNull;
    BOOL backfilled = NO;
    {
        std::lock_guard<std::mutex> lock(_imageMutex);
        for (const auto &item : backfill) {
            _images.insert_or_assign(item.first, ImageOwner(item.second));
            backfilled = YES;
        }
        for (auto it = _images.begin(); it != _images.end();) {
            if (keep.find(it->first) != keep.end()) {
                ++it;
                continue;
            }
            const pager::Rect tile = _document.session.viewport().tileDocumentFrame(it->first);
            const CGRect frame = CGRectMake(tile.x, tile.y, tile.width, tile.height);
            if (!CGRectIsNull(visible) && CGRectIntersectsRect(frame, visible)) {
                ++it;
            } else {
                it = _images.erase(it);
            }
        }
    }
    if (backfilled) {
        [self setNeedsDisplay];
    }
}

- (void)acceptTile:(pager::TileImage)tile {
    if (_document == nil) {
        return;
    }
    CGRect tileFrame = CGRectNull;
    for (const pager::TileSlot &slot : _document.session.viewport().visibleSlots()) {
        if (slot.key == tile.key) {
            tileFrame = CGRectMake(slot.documentFrame.x, slot.documentFrame.y, slot.documentFrame.width,
                                   slot.documentFrame.height);
            break;
        }
    }
    if (CGRectIsNull(tileFrame)) {
        return;
    }
    CGImageRef image = pager::CreateTileCGImage(tile);
    if (image == nullptr) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(_imageMutex);
        _images.insert_or_assign(tile.key, ImageOwner(image));
    }
    [self setNeedsDisplayInRect:tileFrame];
}

- (void)drawRect:(CGRect)rect {
    // CATiledLayer paints on a Core Animation worker. Snapshot + retain so the
    // main thread can replace tiles (zoom / scroll) without freeing an image
    // mid-draw — that was SIGSEGV in CGContextDrawImage.
    std::vector<CGRect> pages;
    std::vector<pager::PageTileBlit> tiles;
    {
        std::lock_guard<std::mutex> lock(_imageMutex);
        if (_document == nil) {
            return;
        }
        const pager::Viewport &viewport = _document.session.viewport();
        for (const pager::PageFrame &frame : viewport.layout().pages()) {
            pages.push_back(CGRectMake(frame.frame.x, frame.frame.y, frame.frame.width, frame.frame.height));
        }
        const int band = pager::ScaleKeyForZoom(viewport.scale());
        std::vector<pager::TileKey> fallbacks;
        for (const auto &entry : _images) {
            if (entry.first.scaleBand != band && entry.second.image != nullptr) {
                fallbacks.push_back(entry.first);
            }
        }
        std::sort(fallbacks.begin(), fallbacks.end(), [](const pager::TileKey &a, const pager::TileKey &b) {
            return a.scaleBand < b.scaleBand;
        });
        auto retain = [&](const pager::TileKey &key, CGImageRef image) {
            if (image == nullptr) {
                return;
            }
            const pager::Rect tile = viewport.tileDocumentFrame(key);
            const pager::Rect page = viewport.layout().pageFrame(key.page);
            tiles.push_back(pager::PageTileBlit{CGRectMake(page.x, page.y, page.width, page.height),
                                                CGRectMake(tile.x, tile.y, tile.width, tile.height), CGImageRetain(image)});
        };
        for (const pager::TileKey &key : fallbacks) {
            const auto found = _images.find(key);
            if (found != _images.end()) {
                retain(key, found->second.image);
            }
        }
        for (const pager::TileSlot &slot : viewport.visibleSlots()) {
            const auto found = _images.find(slot.key);
            if (found != _images.end()) {
                retain(slot.key, found->second.image);
            }
        }
    }
    pager::DrawPageLayer(UIGraphicsGetCurrentContext(), rect, pages, tiles);
    for (const pager::PageTileBlit &tile : tiles) {
        CGImageRelease(tile.image);
    }
}

- (void)setNeedsDisplay {
    [super setNeedsDisplay];
    [_inkOverlay setNeedsDisplay];
}

- (void)setNeedsDisplayInRect:(CGRect)rect {
    [super setNeedsDisplayInRect:rect];
    [_inkOverlay setNeedsDisplay];
}

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

- (CGRect)documentRectForNote:(const pager::Annotation &)note {
    const pager::PageGeometry *page = _document.session.viewport().geometry(note.pageIndex);
    if (page == nullptr) {
        return CGRectZero;
    }
    const pager::Layout &layout = _document.session.viewport().layout();
    const pager::Point a =
        layout.pageViewToDocument(note.pageIndex, pager::UserToPageView(*page, pager::Point{note.bounds.x, note.bounds.y}));
    const pager::Point b = layout.pageViewToDocument(
        note.pageIndex, pager::UserToPageView(*page, pager::Point{note.bounds.x + note.bounds.width, note.bounds.y + note.bounds.height}));
    return CGRectMake(std::min(a.x, b.x), std::min(a.y, b.y), std::abs(a.x - b.x), std::abs(a.y - b.y));
}

- (NSInteger)handleAtDocumentPoint:(pager::Point)point forNote:(const pager::Annotation &)note {
    if (note.kind != pager::AnnotationKind::FreeText && note.kind != pager::AnnotationKind::Square &&
        note.kind != pager::AnnotationKind::Circle) {
        return -1;
    }
    const CGRect rect = CGRectInset([self documentRectForNote:note], -4, -4);
    const CGPoint corners[] = {CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect)),
                               CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect)),
                               CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect)),
                               CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))};
    for (NSInteger index = 0; index < 4; ++index) {
        if (std::hypot(point.x - corners[index].x, point.y - corners[index].y) <= 18) {
            return index;
        }
    }
    if (CGRectContainsPoint(CGRectInset(rect, -6, -6), CGPointMake(point.x, point.y))) {
        return 8;
    }
    return -1;
}

- (void)applyHandle:(NSInteger)handle from:(pager::Point)start to:(pager::Point)current {
    pager::Annotation *note = _document.session.selectedAnnotationMutable();
    if (note == nullptr || _dragPage < 0) {
        return;
    }
    const pager::PageGeometry *page = _document.session.viewport().geometry(_dragPage);
    if (page == nullptr) {
        return;
    }
    const pager::Layout &layout = _document.session.viewport().layout();
    CGRect doc = [self documentRectForNote:*note];
    if (handle == 8) {
        const pager::Point startUser = pager::PageViewToUser(*page, layout.documentToPageView(_dragPage, start));
        const pager::Point currentUser = pager::PageViewToUser(*page, layout.documentToPageView(_dragPage, current));
        const double dx = currentUser.x - startUser.x;
        const double dy = currentUser.y - startUser.y;
        note->bounds.x += dx;
        note->bounds.y += dy;
        _dragStart = current;
        return;
    }
    CGFloat minX = CGRectGetMinX(doc);
    CGFloat minY = CGRectGetMinY(doc);
    CGFloat maxX = CGRectGetMaxX(doc);
    CGFloat maxY = CGRectGetMaxY(doc);
    if (handle == 0) {
        minX = current.x;
        minY = current.y;
    } else if (handle == 1) {
        maxX = current.x;
        minY = current.y;
    } else if (handle == 2) {
        minX = current.x;
        maxY = current.y;
    } else {
        maxX = current.x;
        maxY = current.y;
    }
    if (maxX - minX < 24) {
        maxX = minX + 24;
    }
    if (maxY - minY < 20) {
        maxY = minY + 20;
    }
    const pager::Point userA = pager::PageViewToUser(*page, layout.documentToPageView(_dragPage, pager::Point{minX, minY}));
    const pager::Point userB = pager::PageViewToUser(*page, layout.documentToPageView(_dragPage, pager::Point{maxX, maxY}));
    note->bounds = pager::BoundsOfPoints(userA, userB);
}

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

- (void)beginEditingNote:(const pager::Annotation &)note {
    [self endTextEditing];
    if (note.kind != pager::AnnotationKind::FreeText) {
        return;
    }
    _editingId = note.id;
    _textEditor = [[UITextView alloc] initWithFrame:CGRectInset([self documentRectForNote:note], 4, 3)];
    _textEditor.backgroundColor = UIColor.clearColor;
    _textEditor.opaque = NO;
    _textEditor.text = @(note.contents.c_str());
    _textEditor.delegate = self;
    _textEditor.textContainerInset = UIEdgeInsetsMake(2, 2, 2, 2);
    _textEditor.textContainer.lineFragmentPadding = 0;
    _textEditor.clipsToBounds = YES;
    [self applyEditorStyleFromNote:note];
    _inkOverlay.editingNoteId = note.id;
    _inkOverlay.editor = _textEditor;
    [_inkOverlay addSubview:_textEditor];
    [_inkOverlay setNeedsDisplay];
    [_textEditor becomeFirstResponder];
}

- (void)closeEditorIfNoteGone {
    if (_textEditor == nil || _editingId.value == 0) {
        return;
    }
    if (_document != nil && _document.session.notes().find(_editingId) != nullptr) {
        return;
    }
    [self endTextEditing];
}

- (void)syncTextEditorStyle {
    if (_document == nil || _textEditor == nil || _editingId.value == 0) {
        return;
    }
    const pager::Annotation *note = _document.session.notes().find(_editingId);
    if (note == nullptr) {
        [self closeEditorIfNoteGone];
        return;
    }
    _textEditor.frame = CGRectInset([self documentRectForNote:*note], 4, 3);
    [self applyEditorStyleFromNote:*note];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (_document == nil || textView != _textEditor || _editingId.value == 0) {
        return;
    }
    pager::Annotation *note = _document.session.notes().findMutable(_editingId);
    if (note == nullptr) {
        [self closeEditorIfNoteGone];
        return;
    }
    note->contents = textView.text.UTF8String ?: "";
}

- (void)endTextEditing {
    if (_textEditor == nil) {
        return;
    }
    pager::Annotation *note = _document == nil ? nullptr : _document.session.notes().findMutable(_editingId);
    if (note != nullptr) {
        _document.session.notes().snapshot();
        note->contents = _textEditor.text.UTF8String ?: "";
        [_document saveNotes];
    }
    [_textEditor resignFirstResponder];
    [_textEditor removeFromSuperview];
    _textEditor = nil;
    _editingId = {};
    _inkOverlay.editor = nil;
    _inkOverlay.editingNoteId = {};
    [_inkOverlay setNeedsDisplay];
    [self setNeedsDisplay];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerNotesChanged" object:_document];
}

- (BOOL)textViewShouldEndEditing:(UITextView *)textView {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_textEditor == textView) {
            [self endTextEditing];
        }
    });
    return YES;
}

- (UITouch *)trackedTouchIn:(NSSet<UITouch *> *)touches {
    if (_activeTouch != nil && [touches containsObject:_activeTouch]) {
        return _activeTouch;
    }
    return nil;
}

// While a Pencil stroke is in flight, the resting palm must not pan the scroll view.
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

- (void)refreshLiveStroke {
    [self layoutInkOverlay];
    [_inkOverlay setNeedsDisplay];
}

- (BOOL)markupToolIsActive {
    if (_document == nil) {
        return NO;
    }
    const pager::Tool tool = _document.session.tool();
    return tool == pager::Tool::Highlight || tool == pager::Tool::Underline || tool == pager::Tool::StrikeOut;
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

- (void)clearTextSelection {
    if (_document == nil) {
        return;
    }
    const BOOL hadSelection = !_document.session.selection().quads.empty();
    _document.session.clearSelection();
    if (@available(iOS 16.0, *)) {
        [_editMenu dismissMenu];
    }
    if (hadSelection) {
        [self updateOverlay];
    }
}

- (void)handleDismissSelectionTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    [self clearTextSelection];
}

- (void)selectTextFrom:(pager::Point)start to:(pager::Point)end word:(BOOL)word {
    if (_document == nil) {
        return;
    }
    const int page = _document.session.viewport().layout().pageAt(start);
    const pager::PageGeometry *geometry = page < 0 ? nullptr : _document.session.viewport().geometry(page);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point startView = _document.session.viewport().layout().documentToPageView(page, start);
    const pager::Point endView = _document.session.viewport().layout().documentToPageView(page, end);
    if (word) {
        _document.session.setSelection([_document.source selectionForWordOnPage:page
                                                                        atUser:pager::PageViewToUser(*geometry, startView)]);
    } else {
        _document.session.setSelection([_document.source selectionOnPage:page
                                                                fromUser:pager::PageViewToUser(*geometry, startView)
                                                                  toUser:pager::PageViewToUser(*geometry, endView)]);
    }
    [self updateOverlay];
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
        _textPressStart = point;
        [self selectTextFrom:point to:point word:YES];
        return;
    }
    if (press.state == UIGestureRecognizerStateChanged) {
        [self selectTextFrom:_textPressStart to:point word:NO];
        return;
    }
    if (press.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if (_document.session.selection().quads.empty()) {
        return;
    }
    if (@available(iOS 16.0, *)) {
        UIView *host = [self hostScrollView] ?: self;
        const CGPoint menuPoint = [press locationInView:host];
        if (!std::isfinite(menuPoint.x) || !std::isfinite(menuPoint.y) || self.window == nil) {
            return;
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
                                          UIPasteboard.generalPasteboard.string = @(self_->_document.session.selection().text.c_str());
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
    return [UIMenu menuWithChildren:@[copy, highlight, underline, strike]];
}

- (void)applyMarkupKind:(pager::AnnotationKind)kind {
    if (_document == nil || _document.session.selection().quads.empty()) {
        return;
    }
    pager::Tool tool = pager::Tool::Highlight;
    if (kind == pager::AnnotationKind::Underline) {
        tool = pager::Tool::Underline;
    } else if (kind == pager::AnnotationKind::StrikeOut) {
        tool = pager::Tool::StrikeOut;
    }
    _document.session.addMarkup(kind, _document.session.selection(), _document.session.toolStyle(tool).color);
    _document.session.clearSelection();
    [_document saveNotes];
    [self setNeedsDisplay];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerNotesChanged" object:_document];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_document == nil || (_dragging && _activeTouch != nil)) {
        return;
    }
    const pager::Tool tool = _document.session.tool();
    UITouch *touch = [self preferredTouchIn:touches forTool:tool];
    if (touch == nil) {
        return;
    }
    if ([self toolNeedsPencil:tool] && ![self drawsWithPencil:touch]) {
        return;
    }
    const CGPoint location = [touch locationInView:self];
    _dragStart = pager::Point{location.x, location.y};
    _dragging = true;
    _activeTouch = touch;
    _tappedNote = NO;
    _geometryDirty = NO;
    _editHandle = -1;
    _dragPage = _document.session.viewport().layout().pageAt(_dragStart);
    if (_dragPage < 0) {
        _dragging = false;
        _activeTouch = nil;
        return;
    }
    const pager::PageGeometry *geometry = _document.session.viewport().geometry(_dragPage);
    const pager::Point pageView = _document.session.viewport().layout().documentToPageView(_dragPage, _dragStart);
    const pager::Annotation *selected = _document.session.selectedAnnotation();
    if (selected != nullptr) {
        const NSInteger handle = [self handleAtDocumentPoint:_dragStart forNote:*selected];
        if (handle >= 0) {
            _editHandle = handle;
            _document.session.notes().snapshot();
            _geometryDirty = YES;
            [self setScrollPanSuspended:YES];
            return;
        }
    }
    if (tool == pager::Tool::Scroll || tool == pager::Tool::SelectNote) {
        if (_document.session.selectNoteAt(_dragStart)) {
            _tappedNote = YES;
            [self setNeedsDisplay];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerSelectionChanged" object:_document];
            if (tool == pager::Tool::Scroll) {
                _dragging = false;
                _activeTouch = nil;
            }
            return;
        }
        if (tool == pager::Tool::Scroll) {
            return;
        }
        _dragging = false;
        _activeTouch = nil;
        [self setNeedsDisplay];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerSelectionChanged" object:_document];
        return;
    }
    if (tool == pager::Tool::SelectText || tool == pager::Tool::Highlight || tool == pager::Tool::Underline ||
        tool == pager::Tool::StrikeOut) {
        _document.session.setSelection([_document.source selectionForWordOnPage:_dragPage atUser:pager::PageViewToUser(*geometry, pageView)]);
        [self setNeedsDisplay];
    }
    if (tool == pager::Tool::Highlight || tool == pager::Tool::Underline || tool == pager::Tool::StrikeOut ||
               tool == pager::Tool::Square || tool == pager::Tool::Circle || tool == pager::Tool::Line ||
               tool == pager::Tool::FreeText) {
        [self setScrollPanSuspended:YES];
        if (tool == pager::Tool::Square || tool == pager::Tool::Circle || tool == pager::Tool::Line) {
            pager::AnnotationKind kind = pager::AnnotationKind::Square;
            if (tool == pager::Tool::Circle) {
                kind = pager::AnnotationKind::Circle;
            } else if (tool == pager::Tool::Line) {
                kind = pager::AnnotationKind::Line;
            }
            _document.session.setShapeDraft(kind, _dragPage, pageView, pageView);
            [self setNeedsDisplay];
        }
    } else if (tool == pager::Tool::Eraser) {
        [self setScrollPanSuspended:YES];
    } else if (tool == pager::Tool::Pen || tool == pager::Tool::Marker) {
        [self setScrollPanSuspended:YES];
        _document.session.setPenPage(_dragPage);
        std::vector<pager::InkSample> coalesced;
        for (UITouch *item in [event coalescedTouchesForTouch:touch]) {
            coalesced.push_back(SampleFromTouch(item, self, _document, _dragPage, false));
        }
        if (coalesced.empty()) {
            coalesced.push_back(SampleFromTouch(touch, self, _document, _dragPage, false));
        }
        _document.session.pen().begin(coalesced.front());
        if (coalesced.size() > 1) {
            _document.session.pen().addCoalesced({coalesced.begin() + 1, coalesced.end()});
        }
        std::vector<pager::InkSample> predicted;
        for (UITouch *item in [event predictedTouchesForTouch:touch]) {
            predicted.push_back(SampleFromTouch(item, self, _document, _dragPage, true));
        }
        _document.session.pen().setPredicted(predicted);
        [self refreshLiveStroke];
    }
}

- (void)appendTouchesForTouch:(UITouch *)touch event:(UIEvent *)event {
    if (_dragPage < 0) {
        return;
    }
    std::vector<pager::InkSample> coalesced;
    for (UITouch *item in [event coalescedTouchesForTouch:touch]) {
        coalesced.push_back(SampleFromTouch(item, self, _document, _dragPage, false));
    }
    std::vector<pager::InkSample> predicted;
    for (UITouch *item in [event predictedTouchesForTouch:touch]) {
        predicted.push_back(SampleFromTouch(item, self, _document, _dragPage, true));
    }
    if (!coalesced.empty()) {
        _document.session.pen().addCoalesced(coalesced);
    }
    _document.session.pen().setPredicted(predicted);
    [self refreshLiveStroke];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_dragging || _document == nil || _dragPage < 0) {
        return;
    }
    UITouch *touch = [self trackedTouchIn:touches] ?: [self preferredTouchIn:touches forTool:_document.session.tool()];
    if (touch == nil) {
        return;
    }
    const pager::Tool tool = _document.session.tool();
    const CGPoint location = [touch locationInView:self];
    const pager::Point current{location.x, location.y};
    const pager::PageGeometry *geometry = _document.session.viewport().geometry(_dragPage);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point startView = _document.session.viewport().layout().documentToPageView(_dragPage, _dragStart);
    const pager::Point currentView = _document.session.viewport().layout().documentToPageView(_dragPage, current);
    if (_editHandle >= 0) {
        [self applyHandle:_editHandle from:_dragStart to:current];
        [self syncTextEditorStyle];
        [self setNeedsDisplay];
        return;
    }
    if (tool == pager::Tool::SelectText || tool == pager::Tool::Highlight || tool == pager::Tool::Underline ||
        tool == pager::Tool::StrikeOut) {
        _document.session.setSelection([_document.source selectionOnPage:_dragPage
                                                                 fromUser:pager::PageViewToUser(*geometry, startView)
                                                                   toUser:pager::PageViewToUser(*geometry, currentView)]);
        [self setNeedsDisplay];
    } else if (tool == pager::Tool::Square || tool == pager::Tool::Circle || tool == pager::Tool::Line) {
        pager::AnnotationKind kind = pager::AnnotationKind::Square;
        if (tool == pager::Tool::Circle) {
            kind = pager::AnnotationKind::Circle;
        } else if (tool == pager::Tool::Line) {
            kind = pager::AnnotationKind::Line;
        }
        _document.session.setShapeDraft(kind, _dragPage, startView, currentView);
        [self setNeedsDisplay];
    } else if (tool == pager::Tool::Pen || tool == pager::Tool::Marker) {
        if ([self drawsWithPencil:touch]) {
            [self appendTouchesForTouch:touch event:event];
        }
    } else if (tool == pager::Tool::Eraser) {
        _document.session.eraseAt(_dragPage, *geometry, currentView, 14);
        [self closeEditorIfNoteGone];
        // Saving is deferred to touchesEnded; writing the archive on every move event stalls
        // the main thread at touch frequency.
        _eraseDirty = YES;
        const double pad = 14 * _document.session.viewport().layout().scale() + 4;
        [self setNeedsDisplayInRect:CGRectMake(current.x - pad, current.y - pad, pad * 2, pad * 2)];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [self trackedTouchIn:touches];
    if (touch == nil && _dragging && _document != nil) {
        touch = [self preferredTouchIn:touches forTool:_document.session.tool()];
    }
    if (touch == nil || !_dragging || _document == nil) {
        if (touch != nil || _activeTouch != nil) {
            _dragging = false;
            _activeTouch = nil;
        }
        return;
    }
    _dragging = false;
    _activeTouch = nil;
    [self setScrollPanSuspended:NO];
    const pager::Tool tool = _document.session.tool();
    const pager::PageGeometry *geometry = _document.session.viewport().geometry(_dragPage);
    if (geometry == nullptr) {
        return;
    }
    const CGPoint location = [touch locationInView:self];
    const pager::Point endView = _document.session.viewport().layout().documentToPageView(_dragPage, pager::Point{location.x, location.y});
    const pager::Point startView = _document.session.viewport().layout().documentToPageView(_dragPage, _dragStart);
    const int page = _dragPage;
    if (_editHandle >= 0) {
        const double moved = std::hypot(location.x - _dragStart.x, location.y - _dragStart.y);
        const pager::Annotation *selected = _document.session.selectedAnnotation();
        if (moved <= 10 && _editHandle == 8 && selected != nullptr && selected->kind == pager::AnnotationKind::FreeText) {
            [self beginEditingNote:*selected];
        }
        _editHandle = -1;
        if (_geometryDirty) {
            [_document saveNotes];
            _geometryDirty = NO;
        }
        [self setNeedsDisplay];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerNotesChanged" object:_document];
        return;
    }
    if (tool == pager::Tool::Scroll) {
        if (_tappedNote) {
            _tappedNote = NO;
            return;
        }
        const double moved = std::hypot(location.x - _dragStart.x, location.y - _dragStart.y);
        if (moved <= 12) {
            if (!_document.session.selection().quads.empty()) {
                [self clearTextSelection];
                return;
            }
            const pager::LinkHit link = [_document.source linkOnPage:page atUser:pager::PageViewToUser(*geometry, endView)];
            if (link.found && link.hasDestination) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerScrollToPage" object:_document userInfo:@{
                    @"page" : @(link.pageIndex),
                    @"x" : @(link.point.x),
                    @"y" : @(link.point.y),
                }];
            } else if (link.found && !link.url.empty()) {
                [UIApplication.sharedApplication openURL:[NSURL URLWithString:@(link.url.c_str())] options:@{} completionHandler:nil];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerToggleChrome" object:_document];
            }
        }
        return;
    }
    if (tool == pager::Tool::Highlight || tool == pager::Tool::Underline || tool == pager::Tool::StrikeOut) {
        pager::AnnotationKind kind = pager::AnnotationKind::Highlight;
        if (tool == pager::Tool::Underline) {
            kind = pager::AnnotationKind::Underline;
        } else if (tool == pager::Tool::StrikeOut) {
            kind = pager::AnnotationKind::StrikeOut;
        }
        if (!_document.session.selection().quads.empty()) {
            const pager::ToolStyle style = _document.session.activeStyle();
            _document.session.addMarkup(kind, _document.session.selection(), style.color);
            _document.session.clearSelection();
            [_document saveNotes];
        }
    } else if (tool == pager::Tool::Square || tool == pager::Tool::Circle || tool == pager::Tool::Line) {
        pager::AnnotationKind kind = pager::AnnotationKind::Square;
        if (tool == pager::Tool::Circle) {
            kind = pager::AnnotationKind::Circle;
        } else if (tool == pager::Tool::Line) {
            kind = pager::AnnotationKind::Line;
        }
        const pager::ToolStyle style = _document.session.activeStyle();
        _document.session.clearShapeDraft();
        _document.session.addShape(kind, page, *geometry, startView, endView, style.color, style.lineWidth);
        [_document saveNotes];
    } else if (tool == pager::Tool::FreeText) {
        const pager::ToolStyle style = _document.session.activeStyle();
        const pager::AnnotationId id = _document.session.addTextNote(page, *geometry, endView, "", style.color, style.fontSize);
        _document.session.setSelectedNote(id);
        [_document saveNotes];
        const pager::Annotation *created = _document.session.notes().find(id);
        if (created != nullptr) {
            [self beginEditingNote:*created];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerSelectionChanged" object:_document];
    } else if (tool == pager::Tool::Pen || tool == pager::Tool::Marker) {
        const pager::ToolStyle style = _document.session.activeStyle();
        _document.session.commitPen(page, *geometry, style.color, style.lineWidth, tool == pager::Tool::Pen);
        [_document saveNotes];
        [self setNeedsDisplay];
    }
    if (_eraseDirty) {
        _eraseDirty = NO;
        [_document saveNotes];
    }
    [self setNeedsDisplay];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PagerNotesChanged" object:_document];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_activeTouch != nil && ![touches containsObject:_activeTouch]) {
        return;
    }
    _dragging = false;
    _activeTouch = nil;
    _editHandle = -1;
    if (_document != nil) {
        _document.session.clearShapeDraft();
        _document.session.pen().cancel();
    }
    [self setScrollPanSuspended:NO];
    if (_eraseDirty) {
        _eraseDirty = NO;
        [_document saveNotes];
    }
    [self setNeedsDisplay];
}

@end
