#import "PagerDocumentView.h"

#import "OverlayRenderer.h"
#import "TileImage.hpp"
#import "Zoom.hpp"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Tiled backing store so the canvas can be arbitrarily tall (long documents) without hitting
// layer size limits or allocating a bitmap for the whole document. PDF rasterization already
// happens on the Viewport worker thread, so layer tiles just composite pre-rendered images;
// drawing stays on the main thread (drawsAsynchronously = NO) which keeps all session state
// free of cross-thread data races.
@interface PagerMacTiledLayer : CATiledLayer
@end

@implementation PagerMacTiledLayer

// No fade-in: tiles should appear immediately.
+ (CFTimeInterval)fadeDuration {
    return 0;
}

@end

namespace {

struct ImageOwner {
    CGImageRef image = nullptr;
    ImageOwner() = default;
    explicit ImageOwner(CGImageRef owned) : image(owned) {}
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

struct MacTileClient : pager::TileClient {
    __weak PagerDocumentView *view = nil;
    void tileReady(pager::TileImage image) override {
        auto *box = new pager::TileImage(std::move(image));
        __weak PagerDocumentView *weakView = view;
        dispatch_async(dispatch_get_main_queue(), ^{
            PagerDocumentView *strongView = weakView;
            if (strongView == nil) {
                delete box;
                return;
            }
            [strongView acceptTile:std::move(*box)];
            delete box;
        });
    }
};

}  // namespace

@implementation PagerDocumentView {
    __weak PagerDocument *_document;
    std::unique_ptr<MacTileClient> _client;
    std::mutex _imageMutex;
    std::unordered_map<pager::TileKey, ImageOwner, pager::TileKeyHash> _images;
    pager::Point _dragStart;
    bool _dragging;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _client = std::make_unique<MacTileClient>();
        _client->view = self;
        // We always redraw explicitly; AppKit should never stretch cached content on resize.
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:pager::kCanvasGray alpha:1].CGColor;
    }
    return self;
}

- (CALayer *)makeBackingLayer {
    PagerMacTiledLayer *layer = [[PagerMacTiledLayer alloc] init];
    // 256pt tiles, matching the core tile cache granularity at 2x backing scale.
    layer.tileSize = CGSizeMake(256, 256);
    // One detail level: NSScrollView magnification scales this layer; new rasters
    // refine after the gesture. Rewriting the frame on zoom is what caused flashes.
    layer.levelsOfDetail = 1;
    layer.levelsOfDetailBias = 0;
    layer.drawsAsynchronously = NO;
    return layer;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)attachToDocument:(PagerDocument *)document {
    {
        std::lock_guard<std::mutex> lock(_imageMutex);
        _images.clear();
    }
    _document = document;
    document.session.viewport().setClient(_client.get());
    [self syncFrameAndTiles];
}

- (void)detachViewport {
    if (_document != nil) {
        _document.session.viewport().setClient(nullptr);
    }
    _document = nil;
}

- (void)dealloc {
    [self detachViewport];
}

- (void)syncFrameAndTiles {
    if (_document == nil) {
        return;
    }
    const pager::Size content = _document.session.viewport().layout().contentSize();
    self.frame = NSMakeRect(0, 0, std::max(1.0, content.width), std::max(1.0, content.height));
    [self updateVisibleRect];
    [self setNeedsDisplay:YES];
}

- (void)reloadTilesAfterScale {
    {
        std::lock_guard<std::mutex> lock(_imageMutex);
        _images.clear();
    }
    CATiledLayer *tiled = (CATiledLayer *)self.layer;
    if ([tiled isKindOfClass:[CATiledLayer class]]) {
        const CGSize tileSize = tiled.tileSize;
        tiled.contents = nil;
        tiled.tileSize = CGSizeMake(tileSize.width + 1, tileSize.height + 1);
        tiled.tileSize = tileSize;
        [tiled setNeedsDisplay];
    } else {
        self.layer.contents = nil;
        [self.layer setNeedsDisplay];
    }
    [self syncFrameAndTiles];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window != nil && _document != nil) {
        _document.session.viewport().setScreenScale(self.window.backingScaleFactor);
        [self updateVisibleRect];
    }
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    // Moving between displays with different backing scales invalidates every rendered tile
    // (tile keys don't encode the screen scale), so flush and re-render.
    if (self.window != nil && _document != nil) {
        _document.session.viewport().setScreenScale(self.window.backingScaleFactor);
        _document.session.viewport().invalidateTiles();
        {
            std::lock_guard<std::mutex> lock(_imageMutex);
            _images.clear();
        }
        [self updateVisibleRect];
        [self setNeedsDisplay:YES];
    }
}

- (void)updateVisibleRect {
    if (_document == nil) {
        return;
    }
    const NSRect visible = self.enclosingScrollView.documentVisibleRect;
    _document.session.viewport().setVisibleRect(pager::Rect{visible.origin.x, visible.origin.y, visible.size.width, visible.size.height});
    if (_document.source.rasterSource != nullptr) {
        _document.session.viewport().requestVisibleTiles(*_document.source.rasterSource);
    }
    [self pruneTiles];
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
    const NSRect visible = self.enclosingScrollView.documentVisibleRect;
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
            const NSRect frame = NSMakeRect(tile.x, tile.y, tile.width, tile.height);
            if (NSIntersectsRect(frame, visible)) {
                ++it;
            } else {
                it = _images.erase(it);
            }
        }
    }
    if (backfilled) {
        [self setNeedsDisplay:YES];
    }
}

- (void)acceptTile:(pager::TileImage)tile {
    if (_document == nil) {
        return;
    }
    // Ignore arrivals that are no longer on screen (e.g. rendered for a previous zoom band).
    NSRect tileFrame = NSZeroRect;
    BOOL visible = NO;
    for (const pager::TileSlot &slot : _document.session.viewport().visibleSlots()) {
        if (slot.key == tile.key) {
            tileFrame = NSMakeRect(slot.documentFrame.x, slot.documentFrame.y, slot.documentFrame.width,
                                   slot.documentFrame.height);
            visible = YES;
            break;
        }
    }
    if (!visible) {
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

- (void)drawRect:(NSRect)dirtyRect {
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
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    pager::DrawPageLayer(context, NSRectToCGRect(dirtyRect), pages, tiles);
    if (_document != nil) {
        pager::DrawSessionOverlay(context, NSRectToCGRect(dirtyRect), _document.session, true);
    }
    for (const pager::PageTileBlit &tile : tiles) {
        CGImageRelease(tile.image);
    }
}

- (pager::Point)documentPoint:(NSEvent *)event {
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    return pager::Point{point.x, point.y};
}

- (void)mouseDown:(NSEvent *)event {
    if (_document == nil) {
        return;
    }
    _dragging = true;
    _dragStart = [self documentPoint:event];
    const pager::Tool tool = _document.session.tool();
    const int page = _document.session.viewport().layout().pageAt(_dragStart);
    if (page < 0) {
        return;
    }
    const pager::PageGeometry *geometry = _document.session.viewport().geometry(page);
    const pager::Point pageView = _document.session.viewport().layout().documentToPageView(page, _dragStart);
    if (tool == pager::Tool::Scroll) {
        const pager::LinkHit link = [_document.source linkOnPage:page atUser:pager::PageViewToUser(*geometry, pageView)];
        if (link.found) {
            if (!link.url.empty()) {
                [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@(link.url.c_str())]];
            } else if (link.hasDestination) {
                [_document scrollToPage:link.pageIndex userPoint:link.point];
            }
            _dragging = false;
        } else if (!_document.session.selection().quads.empty()) {
            _document.session.clearSelection();
            [self setNeedsDisplay:YES];
        }
        return;
    }
    if (tool == pager::Tool::SelectNote) {
        _document.session.selectNoteAt(_dragStart);
        _dragging = false;
        [_document syncNoteSelection];
        return;
    }
    if (tool == pager::Tool::SelectText) {
        _document.session.setSelection([_document.source selectionForWordOnPage:page atUser:pager::PageViewToUser(*geometry, pageView)]);
        [self setNeedsDisplay:YES];
    } else if (tool == pager::Tool::Square || tool == pager::Tool::Circle || tool == pager::Tool::Line) {
        pager::AnnotationKind kind = pager::AnnotationKind::Square;
        if (tool == pager::Tool::Circle) {
            kind = pager::AnnotationKind::Circle;
        } else if (tool == pager::Tool::Line) {
            kind = pager::AnnotationKind::Line;
        }
        _document.session.setShapeDraft(kind, page, pageView, pageView);
        [self setNeedsDisplay:YES];
    } else if (tool == pager::Tool::Pen || tool == pager::Tool::Marker) {
        pager::InkSample sample;
        sample.x = pager::PageViewToUser(*geometry, pageView).x;
        sample.y = pager::PageViewToUser(*geometry, pageView).y;
        sample.force = 1;
        sample.time = event.timestamp;
        _document.session.setPenPage(page);
        _document.session.pen().begin(sample);
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging || _document == nil) {
        return;
    }
    const pager::Point current = [self documentPoint:event];
    const pager::Tool tool = _document.session.tool();
    const int page = _document.session.viewport().layout().pageAt(_dragStart);
    const pager::PageGeometry *geometry = page < 0 ? nullptr : _document.session.viewport().geometry(page);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point startView = _document.session.viewport().layout().documentToPageView(page, _dragStart);
    const pager::Point currentView = _document.session.viewport().layout().documentToPageView(page, current);
    if (tool == pager::Tool::SelectText || tool == pager::Tool::Highlight || tool == pager::Tool::Underline ||
        tool == pager::Tool::StrikeOut) {
        _document.session.setSelection([_document.source selectionOnPage:page
                                                                 fromUser:pager::PageViewToUser(*geometry, startView)
                                                                   toUser:pager::PageViewToUser(*geometry, currentView)]);
        [self setNeedsDisplay:YES];
    } else if (tool == pager::Tool::Pen || tool == pager::Tool::Marker) {
        pager::InkSample sample;
        const pager::Point user = pager::PageViewToUser(*geometry, currentView);
        sample.x = user.x;
        sample.y = user.y;
        sample.force = 1;
        sample.time = event.timestamp;
        _document.session.pen().addCoalesced({sample});
        [self setNeedsDisplay:YES];
    } else if (tool == pager::Tool::Square || tool == pager::Tool::Circle || tool == pager::Tool::Line) {
        pager::AnnotationKind kind = pager::AnnotationKind::Square;
        if (tool == pager::Tool::Circle) {
            kind = pager::AnnotationKind::Circle;
        } else if (tool == pager::Tool::Line) {
            kind = pager::AnnotationKind::Line;
        }
        _document.session.setShapeDraft(kind, page, startView, currentView);
        [self setNeedsDisplay:YES];
    } else if (tool == pager::Tool::Eraser) {
        _document.session.eraseAt(page, *geometry, currentView, 12);
        [_document notesDidChange];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (!_dragging || _document == nil) {
        _dragging = false;
        return;
    }
    _dragging = false;
    const pager::Point current = [self documentPoint:event];
    const pager::Tool tool = _document.session.tool();
    const int page = _document.session.viewport().layout().pageAt(_dragStart);
    const pager::PageGeometry *geometry = page < 0 ? nullptr : _document.session.viewport().geometry(page);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point startView = _document.session.viewport().layout().documentToPageView(page, _dragStart);
    const pager::Point endView = _document.session.viewport().layout().documentToPageView(page, current);
    if (tool == pager::Tool::Highlight || tool == pager::Tool::Underline || tool == pager::Tool::StrikeOut) {
        pager::AnnotationKind kind = pager::AnnotationKind::Highlight;
        if (tool == pager::Tool::Underline) {
            kind = pager::AnnotationKind::Underline;
        } else if (tool == pager::Tool::StrikeOut) {
            kind = pager::AnnotationKind::StrikeOut;
        }
        const pager::ToolStyle style = _document.session.activeStyle();
        _document.session.addMarkup(kind, _document.session.selection(), style.color);
        _document.session.clearSelection();
        [_document notesDidChange];
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
        [_document notesDidChange];
    } else if (tool == pager::Tool::FreeText) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Text note";
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        alert.accessoryView = field;
        [alert addButtonWithTitle:@"Add"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn && field.stringValue.length > 0) {
            const pager::ToolStyle style = _document.session.activeStyle();
            _document.session.addTextNote(page, *geometry, endView, field.stringValue.UTF8String, style.color, style.fontSize);
            [_document notesDidChange];
        }
    } else if (tool == pager::Tool::Pen || tool == pager::Tool::Marker) {
        const pager::ToolStyle style = _document.session.activeStyle();
        _document.session.commitPen(page, *geometry, style.color, style.lineWidth, false);
        [_document notesDidChange];
    }
}

- (void)keyDown:(NSEvent *)event {
    const unsigned short deleteKey = 51;
    const unsigned short forwardDeleteKey = 117;
    const NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (_document != nil && (mods & NSEventModifierFlagCommand) && (mods & NSEventModifierFlagOption) &&
        [event.charactersIgnoringModifiers isEqualToString:@"1"]) {
        [_document toggleSidebar:nil];
        return;
    }
    if (_document != nil && (event.keyCode == deleteKey || event.keyCode == forwardDeleteKey) &&
        _document.session.deleteSelectedNote()) {
        [_document notesDidChange];
        return;
    }
    [super keyDown:event];
}

- (void)magnifyWithEvent:(NSEvent *)event {
    // NSScrollView owns pinch magnification so the layer is GPU-scaled in place.
    [super magnifyWithEvent:event];
}

@end
