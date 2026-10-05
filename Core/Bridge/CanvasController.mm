#import "CanvasController.h"

#import "AnnotationGeometry.hpp"
#import "AnnotationRasterizer.h"
#import "OverlayRenderer.h"
#import "ToolPalette.hpp"
#import "Viewport.hpp"
#import "Zoom.hpp"

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

// Rendering model
// ---------------
// Pages are plain CALayers inside the scroll view's zoomed content. Each PDF tile and each
// annotation tile is its own CALayer whose contents is a pre-rendered CGImage, so scrolling
// and zooming are pure GPU compositing and nothing on the main thread redraws per frame.
// Transient content (live ink, shape drafts, a note being dragged, freshly committed notes
// waiting for their tiles) is drawn by the host's screen-sized live view; selection, search
// hits and note chrome are CAShapeLayers. Nothing is ever a document-sized bitmap.

namespace {

constexpr double kEraserRadius = 14;
constexpr double kLiveTailReach = 48;
constexpr CFTimeInterval kPendingTimeout = 0.8;

NSDictionary *NoActions() {
    static NSDictionary *actions = @{
        @"contents" : NSNull.null,
        @"bounds" : NSNull.null,
        @"position" : NSNull.null,
        @"frame" : NSNull.null,
        @"onOrderIn" : NSNull.null,
        @"onOrderOut" : NSNull.null,
        @"sublayers" : NSNull.null,
        @"hidden" : NSNull.null,
        @"path" : NSNull.null,
        @"lineWidth" : NSNull.null,
        @"lineDashPattern" : NSNull.null,
        @"fillColor" : NSNull.null,
        @"strokeColor" : NSNull.null,
        @"zPosition" : NSNull.null,
    };
    return actions;
}

CGRect ToCG(const pager::Rect &rect) { return CGRectMake(rect.x, rect.y, rect.width, rect.height); }

pager::Rect FromCG(CGRect rect) {
    return pager::Rect{rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
}

pager::Rect Pad(const pager::Rect &rect, double amount) {
    if (rect.empty() && rect.x == 0 && rect.y == 0) {
        return rect;
    }
    return pager::Rect{rect.x - amount, rect.y - amount, rect.width + amount * 2, rect.height + amount * 2};
}

// Autoreleased sRGB colour, for layer properties that retain what they are given.
CGColorRef Color(double r, double g, double b, double a) {
    return (CGColorRef)CFAutorelease(CGColorCreateSRGB(r, g, b, a));
}

CGColorRef Color(pager::Color color, float alphaScale) {
    return Color(color.r, color.g, color.b, color.a * alphaScale);
}

pager::Rect SampleBounds(const std::vector<pager::InkSample> &samples, std::size_t from, const pager::PageGeometry &page,
                         const pager::Rect &pageFrame) {
    pager::Rect bounds;
    bool first = true;
    for (std::size_t index = from; index < samples.size(); ++index) {
        const pager::Point view = pager::UserToPageView(page, pager::Point{samples[index].x, samples[index].y});
        const pager::Rect point{pageFrame.x + view.x, pageFrame.y + view.y, 0.01, 0.01};
        bounds = first ? point : bounds.united(point);
        first = false;
    }
    return bounds;
}

struct TileInbox {
    std::mutex mutex;
    std::vector<pager::TileImage> tiles;
    std::vector<pager::AnnotationTile> annotations;
    bool scheduled = false;
};

struct CanvasTileClient : pager::TileClient {
    std::weak_ptr<TileInbox> inbox;
    void (^wake)(void) = nil;
    void tileReady(pager::TileImage image) override {
        std::shared_ptr<TileInbox> box = inbox.lock();
        if (!box) {
            return;
        }
        bool schedule = false;
        {
            std::lock_guard<std::mutex> lock(box->mutex);
            box->tiles.push_back(std::move(image));
            schedule = !box->scheduled;
            box->scheduled = true;
        }
        if (schedule && wake != nil) {
            wake();
        }
    }
};

struct PageLayers {
    CALayer *page = nil;
    CALayer *pdf = nil;
    CALayer *annotations = nil;
};

struct TileLayer {
    CALayer *layer = nil;
    std::uint64_t revision = 0;
};

struct SnapshotEntry {
    std::uint64_t pageRevision = 0;
    std::uint64_t liveId = 0;
    std::uint64_t hideId = 0;
    pager::PageAnnotationsRef snapshot;
};

struct PendingNote {
    pager::Annotation note;
    pager::Rect documentBounds;
    std::uint64_t revision = 0;
    CFTimeInterval created = 0;
};

using TileLayerMap = std::unordered_map<pager::TileKey, TileLayer, pager::TileKeyHash>;

CAShapeLayer *ShapeLayer(CALayer *host) {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.actions = NoActions();
    layer.fillColor = nil;
    layer.strokeColor = nil;
    [host addSublayer:layer];
    return layer;
}

void AddQuad(CGMutablePathRef path, const pager::PageGeometry &page, const pager::Rect &frame, const pager::Quad &quad) {
    for (int corner = 0; corner < 4; ++corner) {
        const pager::Point view = pager::UserToPageView(page, quad.v[corner]);
        if (corner == 0) {
            CGPathMoveToPoint(path, nullptr, frame.x + view.x, frame.y + view.y);
        } else {
            CGPathAddLineToPoint(path, nullptr, frame.x + view.x, frame.y + view.y);
        }
    }
    CGPathCloseSubpath(path);
}

bool IsMarkupTool(pager::Tool tool) {
    return tool == pager::Tool::Highlight || tool == pager::Tool::Underline || tool == pager::Tool::StrikeOut;
}

pager::AnnotationKind ShapeKindFor(pager::Tool tool) {
    if (tool == pager::Tool::Circle) {
        return pager::AnnotationKind::Circle;
    }
    if (tool == pager::Tool::Line) {
        return pager::AnnotationKind::Line;
    }
    return pager::AnnotationKind::Square;
}

pager::AnnotationKind MarkupKindFor(pager::Tool tool) {
    if (tool == pager::Tool::Underline) {
        return pager::AnnotationKind::Underline;
    }
    if (tool == pager::Tool::StrikeOut) {
        return pager::AnnotationKind::StrikeOut;
    }
    return pager::AnnotationKind::Highlight;
}

}  // namespace

@interface PagerCanvasController ()
- (void)drainInbox;
@end

@implementation PagerCanvasController {
    __weak id<PagerCanvasHost> _host;
    __weak id<PagerSessionProvider> _document;
    std::shared_ptr<TileInbox> _inbox;
    std::unique_ptr<CanvasTileClient> _client;
    std::unique_ptr<pager::AnnotationRasterizer> _rasterizer;
    std::uint64_t _epoch;

    CALayer *_pagesLayer;
    CALayer *_chromeLayer;
    CAShapeLayer *_selectionFill;
    CAShapeLayer *_selectionStroke;
    CAShapeLayer *_searchLayer;
    CAShapeLayer *_searchCurrentLayer;
    CAShapeLayer *_noteChrome;
    CAShapeLayer *_noteHandles;

    std::unordered_map<int, PageLayers> _pageLayers;
    TileLayerMap _pdfLayers;
    TileLayerMap _annotationLayers;
    std::unordered_map<int, SnapshotEntry> _snapshots;
    std::uint64_t _snapshotClock;
    std::vector<PendingNote> _pending;
    std::vector<int> _shownPages;
    std::uint64_t _searchRevisionShown;
    std::uint64_t _selectionRevisionShown;
    std::vector<int> _searchPagesShown;
    BOOL _syncScheduled;
    BOOL _zoomingFlag;
    double _chromeZoom;
    int _shownBand;

    pager::Rect _liveTail;
    pager::Rect _liveDraftRect;
    pager::Rect _liveNoteRect;
    pager::AnnotationId _liveNoteId;
    pager::AnnotationId _editingId;
    BOOL _editingIsNew;

    PagerGestureKind _gesture;
    pager::Point _dragStart;
    pager::Point _lastErase;
    pager::Point _lastPoint;
    int _dragPage;
    NSInteger _editHandle;
    BOOL _tappedNote;
    BOOL _geometryDirty;
    BOOL _eraseDirty;
    BOOL _selectingFromPointer;
    std::uint64_t _revisionAtBegin;
}

- (instancetype)initWithPagesLayer:(CALayer *)pagesLayer chromeLayer:(CALayer *)chromeLayer host:(id<PagerCanvasHost>)host {
    self = [super init];
    if (self != nil) {
        _host = host;
        _pagesLayer = pagesLayer;
        _chromeLayer = chromeLayer;
        _dragPage = -1;
        _editHandle = -1;
        _chromeZoom = 1;
        _searchRevisionShown = ~0ull;
        _selectionRevisionShown = ~0ull;
        _inbox = std::make_shared<TileInbox>();
        __weak PagerCanvasController *weakSelf = self;
        void (^wake)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf drainInbox];
            });
        };
        _client = std::make_unique<CanvasTileClient>();
        _client->inbox = _inbox;
        _client->wake = wake;
        _rasterizer = std::make_unique<pager::AnnotationRasterizer>();
        std::weak_ptr<TileInbox> weakInbox = _inbox;
        _rasterizer->setCallback([weakInbox, wake](pager::AnnotationTile tile) {
            std::shared_ptr<TileInbox> box = weakInbox.lock();
            if (!box) {
                return;
            }
            bool schedule = false;
            {
                std::lock_guard<std::mutex> lock(box->mutex);
                box->annotations.push_back(std::move(tile));
                schedule = !box->scheduled;
                box->scheduled = true;
            }
            if (schedule) {
                wake();
            }
        });
        _searchLayer = ShapeLayer(chromeLayer);
        _searchCurrentLayer = ShapeLayer(chromeLayer);
        _selectionFill = ShapeLayer(chromeLayer);
        _selectionStroke = ShapeLayer(chromeLayer);
        _noteChrome = ShapeLayer(chromeLayer);
        _noteHandles = ShapeLayer(chromeLayer);
    }
    return self;
}

- (id<PagerSessionProvider>)document {
    return _document;
}

- (BOOL)zooming {
    return _zoomingFlag;
}

- (pager::AnnotationId)editingNoteId {
    return _editingId;
}

- (PagerGestureKind)gesture {
    return _gesture;
}

- (int)gesturePage {
    return _dragPage;
}

#pragma mark - Lifetime

- (void)resetLayers {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (auto &entry : _pageLayers) {
        [entry.second.page removeFromSuperlayer];
    }
    [CATransaction commit];
    _pageLayers.clear();
    _pdfLayers.clear();
    _annotationLayers.clear();
    _snapshots.clear();
    _pending.clear();
    _shownPages.clear();
    _searchPagesShown.clear();
    _searchRevisionShown = ~0ull;
    _selectionRevisionShown = ~0ull;
    {
        std::lock_guard<std::mutex> lock(_inbox->mutex);
        _inbox->tiles.clear();
        _inbox->annotations.clear();
    }
    _rasterizer->cancelAll();
}

- (void)attachDocument:(id<PagerSessionProvider>)document {
    [self detach];
    ++_epoch;
    [self resetLayers];
    _document = document;
    if (document == nil) {
        return;
    }
    pager::Viewport &viewport = document.session.viewport();
    const CGFloat scale = [_host canvasScreenScale];
    if (scale > 0) {
        viewport.setScreenScale(scale);
    }
    viewport.setClient(_client.get());
    viewport.setSource(document.source.rasterSource);
}

- (void)detach {
    if (_editingId.value != 0) {
        [_host canvasEndTextEditing];
    }
    [self cancelGesture];
    _liveNoteId = {};
    if (_document != nil) {
        _document.session.viewport().setClient(nullptr);
    }
    _document = nil;
    ++_epoch;
    [self resetLayers];
    [_host canvasLiveContentChanged];
    [self updateChrome];
    [self updateSelectionLayers];
}

- (void)shutdown {
    if (_document != nil) {
        _document.session.viewport().setClient(nullptr);
    }
    _document = nil;
    _rasterizer->stop();
}

- (void)dealloc {
    _rasterizer->stop();
}

#pragma mark - Viewport

- (void)refreshViewportScale {
    pager::Viewport &viewport = _document.session.viewport();
    const CGFloat scale = [_host canvasScreenScale];
    if (scale > 0) {
        viewport.setScreenScale(scale);
    }
    viewport.setVisibleRect(FromCG([_host canvasVisibleDocumentRect]));
}

- (void)visibleRectDidChangeWhileZooming {
    if (_document == nil) {
        return;
    }
    _zoomingFlag = YES;
    [self refreshViewportScale];
    // Mid-pinch the current band is about to change; only the cheap base rasters are worth it.
    _document.session.viewport().requestTiles(false, nullptr);
    [self syncPageLayers];
}

- (void)visibleRectDidChange {
    if (_document == nil) {
        return;
    }
    _zoomingFlag = NO;
    pager::Viewport &viewport = _document.session.viewport();
    viewport.setScale([_host canvasZoomScale]);
    [self refreshViewportScale];
    const BOOL placed = [self syncPageLayers];
    if (placed || viewport.band() != _shownBand) {
        _shownBand = viewport.band();
        [self dropCoveredFallbacks:_pdfLayers wanted:nullptr];
    }
    pager::TileKeySet displayed;
    displayed.reserve(_pdfLayers.size());
    for (const auto &entry : _pdfLayers) {
        displayed.insert(entry.first);
    }
    viewport.requestTiles(true, &displayed);
    [self syncAnnotationTiles];
    [self syncSearchLayers:NO];
    if (std::fabs(_chromeZoom - [_host canvasZoomScale]) > 1e-3) {
        [self updateChrome];
        _selectionRevisionShown = ~0ull;
        [self updateSelectionLayers];
    }
    [_host canvasLiveContentChanged];
}

- (void)handleMemoryWarning {
    if (_document == nil) {
        return;
    }
    _document.session.viewport().trimCache();
    const int current = _document.session.viewport().band();
    const int base = _document.session.viewport().baseBand();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (TileLayerMap *map : {&_pdfLayers, &_annotationLayers}) {
        for (auto it = map->begin(); it != map->end();) {
            if (it->first.scaleBand != current && it->first.scaleBand != base) {
                [it->second.layer removeFromSuperlayer];
                it = map->erase(it);
            } else {
                ++it;
            }
        }
    }
    [CATransaction commit];
}

- (void)contentDidChange {
    if (_syncScheduled) {
        return;
    }
    _syncScheduled = YES;
    __weak PagerCanvasController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        PagerCanvasController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            strongSelf->_syncScheduled = NO;
            [strongSelf syncContentNow];
        }
    });
}

- (void)syncContentNow {
    if (_document == nil) {
        [self updateChrome];
        [self updateSelectionLayers];
        return;
    }
    _document.session.sanitizeSelection();
    if (_editingId.value != 0 && _document.session.notes().find(_editingId) == nullptr) {
        [_host canvasEndTextEditing];
    }
    [self syncAnnotationTiles];
    [self syncSearchLayers:NO];
    [self updateSelectionLayers];
    [self updateChrome];
    [self checkPending];
    if (_editingId.value != 0) {
        [_host canvasSyncTextEditor];
    }
    [_host canvasLiveContentChanged];
}

#pragma mark - Page and tile layers

- (PageLayers *)pageLayersFor:(int)pageIndex create:(BOOL)create {
    const auto found = _pageLayers.find(pageIndex);
    if (found != _pageLayers.end()) {
        return &found->second;
    }
    if (!create || _document == nil) {
        return nullptr;
    }
    const pager::Rect frame = _document.session.viewport().layout().pageFrame(pageIndex);
    PageLayers layers;
    layers.page = [CALayer layer];
    layers.page.actions = NoActions();
    layers.page.frame = ToCG(frame);
    layers.page.backgroundColor = Color(1, 1, 1, 1);
    layers.page.opaque = YES;
    layers.page.shadowColor = Color(0, 0, 0, 1);
    layers.page.shadowOpacity = 0.16f;
    layers.page.shadowRadius = 1.5;
    layers.page.shadowOffset = CGSizeMake(0, 2);
    CGPathRef shadow = CGPathCreateWithRect(CGRectInset(CGRectMake(0, 0, frame.width, frame.height), -0.5, -0.5), nullptr);
    // shadowPath copies; release our reference, not the layer's.
    layers.page.shadowPath = shadow;
    CGPathRelease(shadow);
    layers.pdf = [CALayer layer];
    layers.pdf.actions = NoActions();
    layers.pdf.frame = CGRectMake(0, 0, frame.width, frame.height);
    layers.pdf.masksToBounds = YES;
    layers.annotations = [CALayer layer];
    layers.annotations.actions = NoActions();
    layers.annotations.frame = layers.pdf.frame;
    layers.annotations.masksToBounds = YES;
    [layers.page addSublayer:layers.pdf];
    [layers.page addSublayer:layers.annotations];
    [_pagesLayer addSublayer:layers.page];
    return &_pageLayers.emplace(pageIndex, layers).first->second;
}

- (void)removeTilesOnPage:(int)pageIndex from:(TileLayerMap &)map {
    for (auto it = map.begin(); it != map.end();) {
        if (it->first.page == pageIndex) {
            [it->second.layer removeFromSuperlayer];
            it = map.erase(it);
        } else {
            ++it;
        }
    }
}

- (CGFloat)zPositionForBand:(int)band {
    const pager::Viewport &viewport = _document.session.viewport();
    if (band == viewport.band()) {
        return 2;
    }
    return band == viewport.baseBand() ? 0 : 1;
}

- (void)placeTile:(const pager::TileKey &)key image:(CGImageRef)image revision:(std::uint64_t)revision annotation:(BOOL)annotation {
    PageLayers *page = [self pageLayersFor:key.page create:NO];
    if (page == nullptr) {
        return;
    }
    TileLayerMap &map = annotation ? _annotationLayers : _pdfLayers;
    const pager::Viewport &viewport = _document.session.viewport();
    const pager::Rect pageFrame = viewport.layout().pageFrame(key.page);
    const pager::Rect frame = viewport.tileDocumentFrame(key);
    TileLayer &entry = map[key];
    if (entry.layer == nil) {
        entry.layer = [CALayer layer];
        entry.layer.actions = NoActions();
        entry.layer.opaque = !annotation;
        entry.layer.contentsGravity = kCAGravityResize;
        [annotation ? page->annotations : page->pdf addSublayer:entry.layer];
    }
    entry.layer.frame = CGRectMake(frame.x - pageFrame.x, frame.y - pageFrame.y, frame.width, frame.height);
    entry.layer.zPosition = [self zPositionForBand:key.scaleBand];
    // A nil image is a rendered-but-empty annotation tile: keeping the entry records its
    // revision so it is not requested again.
    entry.layer.contents = (__bridge id)image;
    entry.layer.hidden = image == nullptr;
    entry.revision = revision;
}

// A tile from another zoom stays as a placeholder until the current zoom fully covers it.
- (BOOL)coveredByCurrentBand:(const pager::TileKey &)key in:(const TileLayerMap &)map wanted:(const pager::TileKeySet *)wanted {
    const pager::Viewport &viewport = _document.session.viewport();
    const pager::Rect area = viewport.tileDocumentFrame(key).intersection(viewport.prefetchRect());
    if (area.empty()) {
        return true;
    }
    for (const pager::TileSlot &slot : viewport.slots(viewport.band(), area)) {
        if (wanted != nullptr && wanted->count(slot.key) == 0) {
            continue;
        }
        if (map.find(slot.key) == map.end()) {
            return false;
        }
    }
    return true;
}

// Returns YES if any tile was placed from the cache.
- (BOOL)syncPageLayers {
    if (_document == nil) {
        return NO;
    }
    BOOL placed = NO;
    const pager::Viewport &viewport = _document.session.viewport();
    const pager::Rect visible = viewport.visibleRect();
    const pager::Rect prefetch = viewport.prefetchRect();
    const pager::Rect reach{prefetch.x, prefetch.y - visible.height * 0.5, prefetch.width, prefetch.height + visible.height};
    std::vector<int> shown = viewport.layout().pagesIntersecting(reach);
    const int current = viewport.band();
    const int base = viewport.baseBand();

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    std::unordered_set<int> keep(shown.begin(), shown.end());
    for (auto it = _pageLayers.begin(); it != _pageLayers.end();) {
        if (keep.count(it->first) == 0) {
            [self removeTilesOnPage:it->first from:_pdfLayers];
            [self removeTilesOnPage:it->first from:_annotationLayers];
            [it->second.page removeFromSuperlayer];
            _snapshots.erase(it->first);
            it = _pageLayers.erase(it);
        } else {
            ++it;
        }
    }
    for (const int page : shown) {
        [self pageLayersFor:page create:YES];
    }
    _shownPages = shown;

    // Fill in anything the core cache already has.
    std::vector<pager::TileSlot> wanted = viewport.slots(current, prefetch);
    if (base > 0) {
        for (const int page : shown) {
            const std::vector<pager::TileSlot> baseSlots = viewport.slots(base, viewport.layout().pageFrame(page));
            wanted.insert(wanted.end(), baseSlots.begin(), baseSlots.end());
        }
    }
    pager::TileKeySet wantedKeys;
    for (const pager::TileSlot &slot : wanted) {
        wantedKeys.insert(slot.key);
        if (!slot.ready || _pdfLayers.count(slot.key) != 0) {
            continue;
        }
        pager::TileImage image;
        if (viewport.copyTile(slot.key, &image) && image.image) {
            [self placeTile:slot.key image:image.image.get() revision:0 annotation:NO];
            placed = YES;
        }
    }
    for (auto it = _pdfLayers.begin(); it != _pdfLayers.end();) {
        const pager::TileKey &key = it->first;
        bool drop = false;
        if (key.scaleBand == current || key.scaleBand == base) {
            drop = wantedKeys.count(key) == 0;
        } else {
            // Placeholders from another zoom: cheap reach test here; the coverage test runs
            // when sharp tiles arrive (drainInbox), not on every scroll frame.
            drop = !viewport.tileDocumentFrame(key).intersects(reach);
        }
        if (drop) {
            [it->second.layer removeFromSuperlayer];
            it = _pdfLayers.erase(it);
        } else {
            it->second.layer.zPosition = [self zPositionForBand:key.scaleBand];
            ++it;
        }
    }
    [CATransaction commit];
    return placed;
}

- (void)drainInbox {
    std::vector<pager::TileImage> tiles;
    std::vector<pager::AnnotationTile> annotations;
    {
        std::lock_guard<std::mutex> lock(_inbox->mutex);
        tiles.swap(_inbox->tiles);
        annotations.swap(_inbox->annotations);
        _inbox->scheduled = false;
    }
    if (_document == nil) {
        return;
    }
    const pager::Viewport &viewport = _document.session.viewport();
    const int current = viewport.band();
    const int base = viewport.baseBand();
    const pager::Rect prefetch = viewport.prefetchRect();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    bool placedPDF = false;
    for (const pager::TileImage &tile : tiles) {
        if (tile.generation != viewport.generation() || !tile.image) {
            continue;
        }
        if (tile.key.scaleBand != base &&
            (tile.key.scaleBand != current || !viewport.tileDocumentFrame(tile.key).intersects(prefetch))) {
            continue;
        }
        [self placeTile:tile.key image:tile.image.get() revision:0 annotation:NO];
        placedPDF = true;
    }
    for (const pager::AnnotationTile &tile : annotations) {
        if (tile.epoch != _epoch || tile.key.scaleBand != current) {
            continue;
        }
        const auto existing = _annotationLayers.find(tile.key);
        if (existing != _annotationLayers.end() && existing->second.revision > tile.revision) {
            continue;
        }
        [self placeTile:tile.key image:tile.image.get() revision:tile.revision annotation:YES];
    }
    [CATransaction commit];
    if (placedPDF && !_zoomingFlag) {
        [self dropCoveredFallbacks:_pdfLayers wanted:nullptr];
    }
    if (!annotations.empty()) {
        [self dropCoveredFallbacks:_annotationLayers wanted:nullptr];
        [self checkPending];
    }
}

- (void)dropCoveredFallbacks:(TileLayerMap &)map wanted:(const pager::TileKeySet *)wanted {
    const pager::Viewport &viewport = _document.session.viewport();
    const int current = viewport.band();
    const int base = viewport.baseBand();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (auto it = map.begin(); it != map.end();) {
        if (it->first.scaleBand != current && it->first.scaleBand != base &&
            [self coveredByCurrentBand:it->first in:map wanted:wanted]) {
            [it->second.layer removeFromSuperlayer];
            it = map.erase(it);
        } else {
            ++it;
        }
    }
    [CATransaction commit];
}

#pragma mark - Annotation tiles

- (pager::PageAnnotationsRef)snapshotForPage:(int)pageIndex {
    const pager::PageGeometry *page = _document.session.viewport().geometry(pageIndex);
    if (page == nullptr) {
        return nullptr;
    }
    const pager::NoteDocument &notes = _document.session.notes();
    SnapshotEntry &entry = _snapshots[pageIndex];
    const std::uint64_t revision = notes.pageRevision(pageIndex);
    const std::uint64_t live = _liveNoteId.value;
    const std::uint64_t hide = _editingId.value;
    if (entry.snapshot && entry.pageRevision == revision && entry.liveId == live && entry.hideId == hide) {
        return entry.snapshot;
    }
    std::vector<pager::Annotation> onPage;
    for (const pager::Annotation &note : notes.annotations()) {
        if (note.pageIndex == pageIndex && note.id.value != live) {
            onPage.push_back(note);
        }
    }
    entry.pageRevision = revision;
    entry.liveId = live;
    entry.hideId = hide;
    entry.snapshot = pager::MakePageAnnotations(pageIndex, *page, ++_snapshotClock, std::move(onPage), _editingId);
    return entry.snapshot;
}

- (void)syncAnnotationTiles {
    if (_document == nil || _zoomingFlag) {
        return;
    }
    const pager::Viewport &viewport = _document.session.viewport();
    const int current = viewport.band();
    const pager::Rect visible = viewport.visibleRect();
    const pager::Rect prefetch = viewport.prefetchRect();
    const double ppp = pager::ZoomForScaleKey(current) * viewport.screenScale();
    std::vector<pager::AnnotationTileJob> onScreen;
    std::vector<pager::AnnotationTileJob> nearby;
    pager::TileKeySet wanted;
    for (const int pageIndex : _shownPages) {
        pager::PageAnnotationsRef snapshot = [self snapshotForPage:pageIndex];
        if (!snapshot || snapshot->notes.empty()) {
            continue;
        }
        const pager::Rect pageFrame = viewport.layout().pageFrame(pageIndex);
        const pager::Rect area = pageFrame.intersection(prefetch);
        if (area.empty()) {
            continue;
        }
        for (const pager::TileSlot &slot : viewport.slots(current, area)) {
            const pager::Rect pageRect{slot.documentFrame.x - pageFrame.x, slot.documentFrame.y - pageFrame.y,
                                       slot.documentFrame.width, slot.documentFrame.height};
            if (!snapshot->touches(pageRect)) {
                continue;
            }
            wanted.insert(slot.key);
            const auto existing = _annotationLayers.find(slot.key);
            if (existing != _annotationLayers.end() && existing->second.revision >= snapshot->revision) {
                continue;
            }
            pager::AnnotationTileJob job;
            job.key = slot.key;
            job.snapshot = snapshot;
            job.pageRect = pageRect;
            job.pixelsPerPoint = ppp;
            job.pixelWidth = static_cast<int>(std::lround(slot.documentFrame.width * ppp));
            job.pixelHeight = static_cast<int>(std::lround(slot.documentFrame.height * ppp));
            job.epoch = _epoch;
            (slot.documentFrame.intersects(visible) ? onScreen : nearby).push_back(std::move(job));
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (auto it = _annotationLayers.begin(); it != _annotationLayers.end();) {
        // Current-zoom tiles that no longer carry anything (erased, undone, scrolled away)
        // go now; older-zoom placeholders wait until they are covered.
        if (it->first.scaleBand == current && wanted.count(it->first) == 0) {
            [it->second.layer removeFromSuperlayer];
            it = _annotationLayers.erase(it);
        } else {
            ++it;
        }
    }
    [CATransaction commit];
    [self dropCoveredFallbacks:_annotationLayers wanted:&wanted];
    onScreen.insert(onScreen.end(), std::make_move_iterator(nearby.begin()), std::make_move_iterator(nearby.end()));
    _rasterizer->submit(std::move(onScreen));
}

#pragma mark - Pending (just-committed) notes

// The note is drawn as live content until its annotation tiles arrive, so a commit never
// flashes empty for the few milliseconds the rasterizer needs.
- (void)holdNoteUntilRendered:(pager::AnnotationId)identifier {
    if (_document == nil || identifier.value == 0) {
        return;
    }
    const pager::Annotation *note = _document.session.notes().find(identifier);
    const pager::PageGeometry *page = note == nullptr ? nullptr : _document.session.viewport().geometry(note->pageIndex);
    if (page == nullptr) {
        return;
    }
    [self syncAnnotationTiles];
    const auto snapshot = _snapshots.find(note->pageIndex);
    PendingNote pending;
    pending.note = *note;
    pending.documentBounds = [self paintRectForNote:*note];
    pending.revision = snapshot != _snapshots.end() && snapshot->second.snapshot ? snapshot->second.snapshot->revision : 0;
    pending.created = CACurrentMediaTime();
    _pending.push_back(pending);
    [_host canvasLiveContentChanged];
    [self invalidateLive:pending.documentBounds];
    __weak PagerCanvasController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>((kPendingTimeout + 0.05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf checkPending];
                   });
}

- (BOOL)pendingCovered:(const PendingNote &)pending {
    const pager::Viewport &viewport = _document.session.viewport();
    const int pageIndex = pending.note.pageIndex;
    const auto snapshot = _snapshots.find(pageIndex);
    if (snapshot == _snapshots.end() || !snapshot->second.snapshot) {
        return YES;
    }
    const pager::Rect area = pending.documentBounds.intersection(viewport.prefetchRect());
    if (area.empty()) {
        return YES;
    }
    const pager::Rect pageFrame = viewport.layout().pageFrame(pageIndex);
    for (const pager::TileSlot &slot : viewport.slots(viewport.band(), area)) {
        const pager::Rect pageRect{slot.documentFrame.x - pageFrame.x, slot.documentFrame.y - pageFrame.y,
                                   slot.documentFrame.width, slot.documentFrame.height};
        if (!snapshot->second.snapshot->touches(pageRect)) {
            continue;
        }
        const auto layer = _annotationLayers.find(slot.key);
        if (layer == _annotationLayers.end() || layer->second.revision < pending.revision) {
            return NO;
        }
    }
    return YES;
}

- (void)checkPending {
    if (_pending.empty()) {
        return;
    }
    if (_document == nil) {
        _pending.clear();
        [_host canvasLiveContentChanged];
        return;
    }
    const CFTimeInterval now = CACurrentMediaTime();
    for (auto it = _pending.begin(); it != _pending.end();) {
        const bool expired = now - it->created > kPendingTimeout;
        if (expired || (!_zoomingFlag && [self pendingCovered:*it])) {
            [self invalidateLive:it->documentBounds];
            it = _pending.erase(it);
        } else {
            ++it;
        }
    }
    [_host canvasLiveContentChanged];
}

#pragma mark - Live content

- (BOOL)liveHasContent {
    if (_document == nil) {
        return NO;
    }
    const pager::DocumentSession &session = _document.session;
    return session.pen().active() || session.shapeDraft().active || _liveNoteId.value != 0 || !_pending.empty();
}

- (void)invalidateLive:(const pager::Rect &)documentRect {
    if (!documentRect.empty()) {
        [_host canvasInvalidateLiveRect:CGRectInset(ToCG(documentRect), -2, -2)];
    }
}

- (void)drawLiveInContext:(CGContextRef)context documentRect:(CGRect)rect {
    if (_document == nil) {
        return;
    }
    const pager::Rect dirty = FromCG(rect);
    pager::DocumentSession &session = _document.session;
    for (const PendingNote &pending : _pending) {
        if (pending.documentBounds.intersects(dirty)) {
            pager::DrawAnnotationInDocument(context, session, pending.note);
        }
    }
    if (_liveNoteId.value != 0) {
        if (const pager::Annotation *note = session.notes().find(_liveNoteId)) {
            pager::DrawAnnotationInDocument(context, session, *note, _editingId);
        }
    }
    pager::DrawShapeDraft(context, session);
    pager::DrawLivePen(context, session);
}

- (pager::Rect)liveTailBounds {
    const pager::DocumentSession &session = _document.session;
    const pager::PageGeometry *page = session.viewport().geometry(session.penPage());
    if (page == nullptr) {
        return {};
    }
    const std::vector<pager::InkSample> samples = session.pen().display();
    if (samples.empty()) {
        return {};
    }
    // Everything within kLiveTailReach of the tip may change shape as the stroke grows (tail
    // taper, smoothing windows); the rest of the ribbon is already final.
    std::size_t from = samples.size() - 1;
    double reach = 0;
    while (from > 0 && reach < kLiveTailReach) {
        reach += std::hypot(samples[from].x - samples[from - 1].x, samples[from].y - samples[from - 1].y);
        --from;
    }
    const pager::Rect frame = session.viewport().layout().pageFrame(session.penPage());
    const pager::Annotation style = pager::LiveStrokeStyle(session);
    return Pad(SampleBounds(samples, from, *page, frame), pager::StrokeHalfWidthBound(style) + 2);
}

- (void)refreshLiveStroke {
    [_host canvasLiveContentChanged];
    const pager::Rect tail = [self liveTailBounds];
    [self invalidateLive:tail.united(_liveTail)];
    _liveTail = tail;
}

- (pager::Rect)documentRectForDraft {
    const pager::ShapeDraft &draft = _document.session.shapeDraft();
    if (!draft.active) {
        return {};
    }
    const pager::Rect frame = _document.session.viewport().layout().pageFrame(draft.pageIndex);
    const pager::Rect rect = pager::BoundsOfPoints(draft.start, draft.current);
    return Pad(pager::Rect{frame.x + rect.x, frame.y + rect.y, rect.width, rect.height}, draft.lineWidth + 3);
}

- (void)refreshLiveDraft {
    [_host canvasLiveContentChanged];
    const pager::Rect rect = [self documentRectForDraft];
    [self invalidateLive:rect.united(_liveDraftRect)];
    _liveDraftRect = rect;
}

- (pager::Rect)paintRectForNote:(const pager::Annotation &)note {
    const pager::PageGeometry *page = _document.session.viewport().geometry(note.pageIndex);
    if (page == nullptr) {
        return {};
    }
    const pager::Rect frame = _document.session.viewport().layout().pageFrame(note.pageIndex);
    const pager::Rect paint = pager::PageViewPaintBounds(*page, note);
    return pager::Rect{frame.x + paint.x, frame.y + paint.y, paint.width, paint.height};
}

- (void)refreshLiveNote {
    [_host canvasLiveContentChanged];
    const pager::Annotation *note = _document.session.notes().find(_liveNoteId);
    const pager::Rect rect = note == nullptr ? pager::Rect{} : [self paintRectForNote:*note];
    [self invalidateLive:rect.united(_liveNoteRect)];
    _liveNoteRect = rect;
}

- (void)beginLiveNote:(pager::AnnotationId)identifier {
    _liveNoteId = identifier;
    _liveNoteRect = {};
    // The note leaves its page's tiles while it moves; live content draws it instead.
    [self syncAnnotationTiles];
    [self refreshLiveNote];
}

- (void)endLiveNote {
    const pager::AnnotationId identifier = _liveNoteId;
    if (identifier.value == 0) {
        return;
    }
    _liveNoteId = {};
    [self invalidateLive:_liveNoteRect];
    _liveNoteRect = {};
    [self holdNoteUntilRendered:identifier];
}

#pragma mark - Chrome (selection, search, note frame)

- (void)updateSelectionLayers {
    if (_document == nil) {
        _selectionFill.path = nil;
        _selectionStroke.path = nil;
        _selectionRevisionShown = ~0ull;
        return;
    }
    const pager::DocumentSession &session = _document.session;
    if (session.selectionRevision() == _selectionRevisionShown) {
        return;
    }
    _selectionRevisionShown = session.selectionRevision();
    const pager::TextSelection &selection = session.selection();
    const pager::Tool tool = session.tool();
    const pager::Viewport &viewport = session.viewport();
    CGMutablePathRef fill = CGPathCreateMutable();
    CGMutablePathRef stroke = CGPathCreateMutable();
    const bool markup = IsMarkupTool(tool);
    for (const pager::SelectionQuad &quad : selection.quads) {
        const pager::PageGeometry *page = viewport.geometry(quad.pageIndex);
        if (page == nullptr) {
            continue;
        }
        const pager::Rect frame = viewport.layout().pageFrame(quad.pageIndex);
        if (!markup || tool == pager::Tool::Highlight) {
            AddQuad(fill, *page, frame, quad.quad);
            continue;
        }
        pager::Point a = quad.quad.v[0];
        pager::Point b = quad.quad.v[1];
        if (tool == pager::Tool::StrikeOut) {
            a = pager::Point{(quad.quad.v[0].x + quad.quad.v[3].x) * 0.5, (quad.quad.v[0].y + quad.quad.v[3].y) * 0.5};
            b = pager::Point{(quad.quad.v[1].x + quad.quad.v[2].x) * 0.5, (quad.quad.v[1].y + quad.quad.v[2].y) * 0.5};
        }
        const pager::Point va = pager::UserToPageView(*page, a);
        const pager::Point vb = pager::UserToPageView(*page, b);
        CGPathMoveToPoint(stroke, nullptr, frame.x + va.x, frame.y + va.y);
        CGPathAddLineToPoint(stroke, nullptr, frame.x + vb.x, frame.y + vb.y);
    }
    const pager::ToolStyle style = session.activeStyle();
    if (markup && tool == pager::Tool::Highlight) {
        const float alpha = style.color.a > 0.01f && style.color.a < 0.85f ? 1 : 0.4f;
        _selectionFill.fillColor = Color(style.color, alpha);
    } else {
        _selectionFill.fillColor = Color(0.2, 0.45, 0.95, 0.28);
    }
    _selectionStroke.strokeColor = Color(style.color.a == 0 ? pager::Color{0, 0, 0, 1} : style.color, 1);
    _selectionStroke.lineWidth = std::max(1.0f, style.lineWidth);
    _selectionFill.path = fill;
    _selectionStroke.path = stroke;
    CGPathRelease(fill);
    CGPathRelease(stroke);
}

- (void)syncSearchLayers:(BOOL)force {
    if (_document == nil) {
        _searchLayer.path = nil;
        _searchCurrentLayer.path = nil;
        return;
    }
    const pager::DocumentSession &session = _document.session;
    if (!force && session.searchRevision() == _searchRevisionShown && _searchPagesShown == _shownPages) {
        return;
    }
    _searchRevisionShown = session.searchRevision();
    _searchPagesShown = _shownPages;
    const pager::Viewport &viewport = session.viewport();
    std::unordered_set<int> shown(_shownPages.begin(), _shownPages.end());
    CGMutablePathRef all = CGPathCreateMutable();
    CGMutablePathRef current = CGPathCreateMutable();
    const int count = static_cast<int>(session.searchHits().size());
    for (int index = 0; index < count; ++index) {
        for (const pager::SelectionQuad &quad : session.searchHits()[static_cast<std::size_t>(index)].quads) {
            const pager::PageGeometry *page = viewport.geometry(quad.pageIndex);
            if (page == nullptr || shown.count(quad.pageIndex) == 0) {
                continue;
            }
            AddQuad(index == session.searchIndex() ? current : all, *page, viewport.layout().pageFrame(quad.pageIndex),
                    quad.quad);
        }
    }
    _searchLayer.fillColor = Color(1, 0.85, 0.1, 0.25);
    _searchCurrentLayer.fillColor = Color(1, 0.55, 0.1, 0.45);
    _searchLayer.path = all;
    _searchCurrentLayer.path = current;
    CGPathRelease(all);
    CGPathRelease(current);
}

- (CGRect)documentRectForNote:(const pager::Annotation &)note {
    if (_document == nil) {
        return CGRectZero;
    }
    const pager::PageGeometry *page = _document.session.viewport().geometry(note.pageIndex);
    if (page == nullptr) {
        return CGRectZero;
    }
    const pager::Layout &layout = _document.session.viewport().layout();
    if (note.kind == pager::AnnotationKind::Ink || note.kind == pager::AnnotationKind::Line || !note.quads.empty()) {
        return ToCG([self paintRectForNote:note]);
    }
    const pager::Point a =
        layout.pageViewToDocument(note.pageIndex, pager::UserToPageView(*page, pager::Point{note.bounds.x, note.bounds.y}));
    const pager::Point b = layout.pageViewToDocument(
        note.pageIndex, pager::UserToPageView(*page, pager::Point{note.bounds.x + note.bounds.width, note.bounds.y + note.bounds.height}));
    return CGRectMake(std::min(a.x, b.x), std::min(a.y, b.y), std::abs(a.x - b.x), std::abs(a.y - b.y));
}

- (BOOL)noteIsResizable:(const pager::Annotation &)note {
    return note.kind == pager::AnnotationKind::FreeText || note.kind == pager::AnnotationKind::Square ||
           note.kind == pager::AnnotationKind::Circle;
}

- (BOOL)noteIsMovable:(const pager::Annotation &)note {
    return [self noteIsResizable:note] || note.kind == pager::AnnotationKind::Ink || note.kind == pager::AnnotationKind::Line;
}

- (double)zoom {
    return std::max(0.05, [_host canvasZoomScale]);
}

- (CGRect)chromeRectForNote:(const pager::Annotation &)note {
    const double zoom = [self zoom];
    return CGRectInset([self documentRectForNote:note], -4 / zoom, -4 / zoom);
}

- (void)updateChrome {
    const pager::Annotation *selected = _document == nil ? nullptr : _document.session.selectedAnnotation();
    const double zoom = [self zoom];
    _chromeZoom = [_host canvasZoomScale];
    if (selected == nullptr) {
        _noteChrome.path = nil;
        _noteHandles.path = nil;
        return;
    }
    const CGRect rect = [self chromeRectForNote:*selected];
    CGPathRef outline = CGPathCreateWithRect(rect, nullptr);
    _noteChrome.path = outline;
    CGPathRelease(outline);
    _noteChrome.strokeColor = Color(0.15, 0.45, 0.95, 1);
    _noteChrome.lineWidth = 1.5 / zoom;
    _noteChrome.lineDashPattern = @[@(5 / zoom), @(3 / zoom)];
    CGMutablePathRef handles = CGPathCreateMutable();
    if ([self noteIsResizable:*selected]) {
        const CGFloat size = 8 / zoom;
        const CGPoint corners[] = {CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect)),
                                   CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect)),
                                   CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect)),
                                   CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))};
        for (const CGPoint corner : corners) {
            CGPathAddEllipseInRect(handles, nullptr, CGRectMake(corner.x - size * 0.5, corner.y - size * 0.5, size, size));
        }
    }
    _noteHandles.path = handles;
    _noteHandles.fillColor = Color(0.15, 0.45, 0.95, 1);
    CGPathRelease(handles);
}

#pragma mark - Hit testing

- (NSInteger)handleAtDocumentPoint:(pager::Point)point forNote:(const pager::Annotation &)note {
    if (![self noteIsMovable:note]) {
        return -1;
    }
    const double zoom = [self zoom];
    const CGRect rect = [self chromeRectForNote:note];
    if ([self noteIsResizable:note]) {
        const CGPoint corners[] = {CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect)),
                                   CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect)),
                                   CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect)),
                                   CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))};
        const double reach = (_pointerSelectsText ? 9 : 18) / zoom;
        for (NSInteger index = 0; index < 4; ++index) {
            if (std::hypot(point.x - corners[index].x, point.y - corners[index].y) <= reach) {
                return index;
            }
        }
    }
    if (CGRectContainsPoint(CGRectInset(rect, -6 / zoom, -6 / zoom), CGPointMake(point.x, point.y))) {
        return 8;
    }
    return -1;
}

- (NSInteger)handleAt:(pager::Point)point {
    const pager::Annotation *selected = _document == nil ? nullptr : _document.session.selectedAnnotation();
    return selected == nullptr ? -1 : [self handleAtDocumentPoint:point forNote:*selected];
}

- (const pager::Annotation *)noteAt:(pager::Point)point {
    if (_document == nil) {
        return nullptr;
    }
    pager::DocumentSession &session = _document.session;
    const int pageIndex = session.viewport().layout().pageAt(point);
    const pager::PageGeometry *page = pageIndex < 0 ? nullptr : session.viewport().geometry(pageIndex);
    if (page == nullptr) {
        return nullptr;
    }
    const pager::Point pageView = session.viewport().layout().documentToPageView(pageIndex, point);
    const auto &notes = session.notes().annotations();
    for (auto note = notes.rbegin(); note != notes.rend(); ++note) {
        if (note->pageIndex == pageIndex && pager::HitsAnnotation(*note, *page, pageView, 8 / [self zoom])) {
            return &*note;
        }
    }
    return nullptr;
}

- (void)applyHandle:(NSInteger)handle from:(pager::Point)start to:(pager::Point)current {
    pager::Annotation *note = _document.session.selectedAnnotationMutable();
    if (note == nullptr || _dragPage < 0) {
        return;
    }
    const pager::PageGeometry *page = _document.session.viewport().geometry(note->pageIndex);
    if (page == nullptr) {
        return;
    }
    const pager::Layout &layout = _document.session.viewport().layout();
    if (handle == 8) {
        const pager::Point startUser = pager::PageViewToUser(*page, layout.documentToPageView(note->pageIndex, start));
        const pager::Point currentUser = pager::PageViewToUser(*page, layout.documentToPageView(note->pageIndex, current));
        const double dx = currentUser.x - startUser.x;
        const double dy = currentUser.y - startUser.y;
        note->bounds.x += dx;
        note->bounds.y += dy;
        note->lineStart.x += dx;
        note->lineStart.y += dy;
        note->lineEnd.x += dx;
        note->lineEnd.y += dy;
        for (pager::InkSample &sample : note->samples) {
            sample.x += dx;
            sample.y += dy;
        }
        _dragStart = current;
        return;
    }
    const CGRect doc = [self documentRectForNote:*note];
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
    const pager::Point userA = pager::PageViewToUser(*page, layout.documentToPageView(note->pageIndex, pager::Point{minX, minY}));
    const pager::Point userB = pager::PageViewToUser(*page, layout.documentToPageView(note->pageIndex, pager::Point{maxX, maxY}));
    note->bounds = pager::BoundsOfPoints(userA, userB);
}

#pragma mark - Text selection and markup

- (void)selectTextFrom:(pager::Point)start to:(pager::Point)end word:(BOOL)word {
    if (_document == nil) {
        return;
    }
    pager::DocumentSession &session = _document.session;
    const int page = session.viewport().layout().pageAt(start);
    const pager::PageGeometry *geometry = page < 0 ? nullptr : session.viewport().geometry(page);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point startView = session.viewport().layout().documentToPageView(page, start);
    const pager::Point endView = session.viewport().layout().documentToPageView(page, end);
    PDFKitPageSource *source = _document.source;
    if (word) {
        session.setSelection([source selectionForWordOnPage:page atUser:pager::PageViewToUser(*geometry, startView)]);
    } else {
        session.setSelection([source selectionOnPage:page
                                            fromUser:pager::PageViewToUser(*geometry, startView)
                                              toUser:pager::PageViewToUser(*geometry, endView)]);
    }
    [self updateSelectionLayers];
}

- (BOOL)clearTextSelection {
    if (_document == nil || _document.session.selection().quads.empty()) {
        return NO;
    }
    _document.session.clearSelection();
    [self updateSelectionLayers];
    return YES;
}

- (void)holdNotesFrom:(std::size_t)firstIndex {
    const auto &notes = _document.session.notes().annotations();
    std::vector<pager::AnnotationId> added;
    for (std::size_t index = firstIndex; index < notes.size(); ++index) {
        added.push_back(notes[index].id);
    }
    for (const pager::AnnotationId identifier : added) {
        [self holdNoteUntilRendered:identifier];
    }
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
    pager::DocumentSession &session = _document.session;
    const pager::ToolStyle style = session.toolStyle(tool);
    const std::size_t before = session.notes().annotations().size();
    session.addMarkup(kind, session.selection(), style.color, style.lineWidth);
    session.clearSelection();
    [self holdNotesFrom:before];
    [self finishEdit];
}

#pragma mark - Notes

- (void)finishEdit {
    [_document saveNotes];
    [self contentDidChange];
    [_host canvasNotesChanged];
}

- (void)deleteSelectedNote {
    if (_document == nil) {
        return;
    }
    if (_editingId.value != 0) {
        [_host canvasEndTextEditing];
    }
    if (_document.session.deleteSelectedNote()) {
        [self finishEdit];
        [_host canvasSelectionChanged];
    }
}

- (BOOL)applyColorToSelection:(pager::Color)color {
    if (_document == nil) {
        return NO;
    }
    const pager::Annotation *selected = _document.session.selectedAnnotation();
    if (selected == nullptr) {
        return NO;
    }
    if (_document.session.notes().update(selected->id, [&](pager::Annotation &note) { note.color = color; })) {
        [self finishEdit];
    }
    return YES;
}

- (BOOL)applySizeToSelection:(float)size {
    if (_document == nil) {
        return NO;
    }
    const pager::Annotation *selected = _document.session.selectedAnnotation();
    if (selected == nullptr) {
        return NO;
    }
    const bool changed = _document.session.notes().update(selected->id, [&](pager::Annotation &note) {
        if (note.kind == pager::AnnotationKind::FreeText) {
            note.fontSize = size;
        } else {
            note.lineWidth = size;
        }
    });
    if (changed) {
        [self finishEdit];
    }
    return YES;
}

#pragma mark - Text editing

- (void)beginEditingNote:(pager::AnnotationId)identifier isNew:(BOOL)isNew {
    if (_document == nil || _document.session.notes().find(identifier) == nullptr) {
        return;
    }
    _editingId = identifier;
    _editingIsNew = isNew;
    _document.session.notes().beginEdit(identifier);
    [self syncAnnotationTiles];
}

- (void)editingTextDidChange:(const std::string &)text {
    if (_document == nil || _editingId.value == 0) {
        return;
    }
    if (pager::Annotation *note = _document.session.notes().findMutable(_editingId)) {
        note->contents = text;
    }
}

- (void)finishEditingWithText:(const std::string &)text {
    const pager::AnnotationId identifier = _editingId;
    const BOOL isNew = _editingIsNew;
    _editingId = {};
    _editingIsNew = NO;
    id<PagerSessionProvider> document = _document;
    if (document == nil || identifier.value == 0) {
        return;
    }
    pager::NoteDocument &notes = document.session.notes();
    BOOL changed = NO;
    if (pager::Annotation *note = notes.findMutable(identifier)) {
        note->contents = text;
        if (isNew && note->contents.empty()) {
            // An abandoned empty box leaves neither a note nor an undo step.
            notes.discardAdd(identifier);
            document.session.sanitizeSelection();
            changed = YES;
        } else {
            changed = notes.endEdit(identifier, isNew);
        }
    } else {
        notes.endEdit(identifier);
    }
    if (notes.find(identifier) != nullptr) {
        [self holdNoteUntilRendered:identifier];
    }
    if (changed) {
        [document saveNotes];
    }
    [self contentDidChange];
    [_host canvasNotesChanged];
}

#pragma mark - Gestures

- (pager::InkSample)inkSampleAt:(pager::Point)documentPoint
                          force:(float)force
                       altitude:(float)altitude
                        azimuth:(float)azimuth
                           time:(double)time
                      predicted:(BOOL)predicted {
    pager::InkSample sample;
    sample.predicted = predicted;
    sample.force = force;
    sample.altitude = altitude;
    sample.azimuth = azimuth;
    sample.time = time;
    const pager::PageGeometry *geometry = _document == nil ? nullptr : _document.session.viewport().geometry(_dragPage);
    if (geometry == nullptr) {
        return sample;
    }
    pager::Point pageView = _document.session.viewport().layout().documentToPageView(_dragPage, documentPoint);
    // Clip to the page so a stroke that crosses the page edge rides along the edge instead of
    // landing at nonsense coordinates in the page's user space.
    const pager::Size displayed = pager::DisplayedSize(*geometry);
    pageView.x = std::clamp(pageView.x, 0.0, displayed.width);
    pageView.y = std::clamp(pageView.y, 0.0, displayed.height);
    const pager::Point user = pager::PageViewToUser(*geometry, pageView);
    sample.x = user.x;
    sample.y = user.y;
    return sample;
}

- (PagerGestureKind)beginGestureAt:(pager::Point)point clickCount:(NSInteger)clickCount {
    [self cancelGesture];
    if (_document == nil) {
        return PagerGestureNone;
    }
    pager::DocumentSession &session = _document.session;
    const pager::Tool tool = session.tool();
    if (_editingId.value != 0) {
        const pager::Annotation *editing = session.notes().find(_editingId);
        if (editing == nullptr || !CGRectContainsPoint([self documentRectForNote:*editing], CGPointMake(point.x, point.y))) {
            // The press only commits the text; it must not start a second box or a selection.
            [_host canvasEndTextEditing];
            if (tool == pager::Tool::FreeText) {
                [_host canvasSelectTool:pager::Tool::Scroll];
            }
            return PagerGestureNone;
        }
    }
    _dragStart = point;
    _lastPoint = point;
    _lastErase = point;
    _tappedNote = NO;
    _geometryDirty = NO;
    _eraseDirty = NO;
    _selectingFromPointer = NO;
    _editHandle = -1;
    _revisionAtBegin = session.notes().revision();
    _dragPage = session.viewport().layout().pageAt(point);
    if (_dragPage < 0) {
        if (_pointerSelectsText && (tool == pager::Tool::Scroll || tool == pager::Tool::SelectNote)) {
            [self clearTextSelection];
            if (session.selectedNote().value != 0) {
                session.setSelectedNote({});
                [self updateChrome];
                [_host canvasSelectionChanged];
            }
        }
        return PagerGestureNone;
    }
    const pager::PageGeometry *geometry = session.viewport().geometry(_dragPage);
    const pager::Point pageView = session.viewport().layout().documentToPageView(_dragPage, point);
    if (const pager::Annotation *selected = session.selectedAnnotation()) {
        const NSInteger handle = [self handleAtDocumentPoint:point forNote:*selected];
        if (handle >= 0) {
            if (clickCount >= 2 && selected->kind == pager::AnnotationKind::FreeText) {
                [_host canvasEditNote:selected->id isNew:NO];
                return PagerGestureNone;
            }
            _editHandle = handle;
            session.notes().beginEdit(selected->id);
            [_host canvasSetPanSuspended:YES];
            return _gesture = PagerGestureHandle;
        }
    }
    if (tool == pager::Tool::Scroll || tool == pager::Tool::SelectNote) {
        const pager::AnnotationId before = session.selectedNote();
        const BOOL hit = session.selectNoteAt(point);
        if (!(before == session.selectedNote())) {
            [self updateChrome];
            [_host canvasSelectionChanged];
        }
        // A press that only dismisses something (a selected note, selected text) is not a
        // background tap, so it must not also toggle the controls.
        _tappedNote = !hit && before.value != 0;
        if (hit) {
            [self clearTextSelection];
            const pager::Annotation *selected = session.selectedAnnotation();
            if (clickCount >= 2 && selected->kind == pager::AnnotationKind::FreeText) {
                [_host canvasEditNote:selected->id isNew:NO];
                return PagerGestureNone;
            }
            if (_pointerSelectsText && [self noteIsMovable:*selected]) {
                // Preview behaviour: press on a note and drag moves it right away.
                const NSInteger handle = [self handleAtDocumentPoint:point forNote:*selected];
                _editHandle = handle >= 0 ? handle : 8;
                session.notes().beginEdit(selected->id);
                _tappedNote = YES;
                return _gesture = PagerGestureHandle;
            }
            if (_pointerSelectsText) {
                // Markup is anchored to its text: the click selects it, a drag selects text.
                _tappedNote = YES;
                _selectingFromPointer = YES;
                return _gesture = PagerGestureTextSelection;
            }
            _tappedNote = YES;
            return _gesture = PagerGestureTap;
        }
        if (_pointerSelectsText && tool == pager::Tool::Scroll) {
            _selectingFromPointer = YES;
            if (clickCount >= 2) {
                [self selectTextFrom:point to:point word:YES];
                _tappedNote = YES;
            } else if ([self clearTextSelection]) {
                _tappedNote = YES;
            }
            return _gesture = PagerGestureTextSelection;
        }
        return _gesture = PagerGestureTap;
    }
    if (tool == pager::Tool::SelectText || IsMarkupTool(tool)) {
        session.setSelection([_document.source selectionForWordOnPage:_dragPage
                                                               atUser:pager::PageViewToUser(*geometry, pageView)]);
        [self updateSelectionLayers];
        if (IsMarkupTool(tool)) {
            [_host canvasSetPanSuspended:YES];
        }
        return _gesture = PagerGestureTextSelection;
    }
    if (tool == pager::Tool::Square || tool == pager::Tool::Circle || tool == pager::Tool::Line) {
        [_host canvasSetPanSuspended:YES];
        session.setShapeDraft(ShapeKindFor(tool), _dragPage, pageView, pageView);
        _liveDraftRect = {};
        [self refreshLiveDraft];
        return _gesture = PagerGestureShape;
    }
    if (tool == pager::Tool::FreeText) {
        [_host canvasSetPanSuspended:YES];
        return _gesture = PagerGestureTextBox;
    }
    if (tool == pager::Tool::Eraser) {
        [_host canvasSetPanSuspended:YES];
        session.notes().beginGroup();
        _gesture = PagerGestureEraser;
        [self eraseTo:point];
        return _gesture;
    }
    if (tool == pager::Tool::Pen || tool == pager::Tool::Marker) {
        [_host canvasSetPanSuspended:YES];
        session.setPenPage(_dragPage);
        _liveTail = {};
        return _gesture = PagerGestureInk;
    }
    return PagerGestureNone;
}

- (std::vector<std::size_t>)beginInk:(const std::vector<pager::InkSample> &)samples
                           predicted:(const std::vector<pager::InkSample> &)predicted {
    std::vector<std::size_t> indices;
    if (_gesture != PagerGestureInk || samples.empty()) {
        return indices;
    }
    pager::StrokeBuilder &pen = _document.session.pen();
    pen.begin(samples.front());
    indices.push_back(0);
    if (samples.size() > 1) {
        const std::vector<std::size_t> rest = pen.addCoalesced({samples.begin() + 1, samples.end()});
        indices.insert(indices.end(), rest.begin(), rest.end());
    }
    pen.setPredicted(predicted);
    [self refreshLiveStroke];
    return indices;
}

- (std::vector<std::size_t>)appendInk:(const std::vector<pager::InkSample> &)samples
                            predicted:(const std::vector<pager::InkSample> &)predicted {
    std::vector<std::size_t> indices;
    if (_gesture != PagerGestureInk || !_document.session.pen().active()) {
        return indices;
    }
    pager::StrokeBuilder &pen = _document.session.pen();
    if (!samples.empty()) {
        indices = pen.addCoalesced(samples);
    }
    pen.setPredicted(predicted);
    [self refreshLiveStroke];
    return indices;
}

- (void)updateInkSample:(std::size_t)index force:(float)force altitude:(float)altitude azimuth:(float)azimuth {
    if (_document == nil || !_document.session.pen().updateSample(index, force, altitude, azimuth)) {
        return;
    }
    // Late force lands near the tip, which is inside the tail region anyway.
    [self invalidateLive:[self liveTailBounds].united(_liveTail)];
}

- (void)eraseTo:(pager::Point)documentPoint {
    const pager::PageGeometry *geometry = _document.session.viewport().geometry(_dragPage);
    if (geometry == nullptr) {
        return;
    }
    const pager::Layout &layout = _document.session.viewport().layout();
    const pager::Point from = layout.documentToPageView(_dragPage, _lastErase);
    const pager::Point to = layout.documentToPageView(_dragPage, documentPoint);
    // A constant on-screen eraser size, like PDF Expert: smaller in page units when zoomed in.
    const double radius = kEraserRadius / std::max(0.5, [self zoom]);
    if (_document.session.eraseAlong(_dragPage, *geometry, from, to, radius)) {
        _eraseDirty = YES;
        if (_editingId.value != 0 && _document.session.notes().find(_editingId) == nullptr) {
            [_host canvasEndTextEditing];
        }
        [self syncAnnotationTiles];
        [self updateChrome];
    }
    _lastErase = documentPoint;
}

- (void)moveGestureTo:(pager::Point)point {
    if (_document == nil || _dragPage < 0) {
        return;
    }
    pager::DocumentSession &session = _document.session;
    const pager::PageGeometry *geometry = session.viewport().geometry(_dragPage);
    if (geometry == nullptr) {
        return;
    }
    _lastPoint = point;
    const pager::Point startView = session.viewport().layout().documentToPageView(_dragPage, _dragStart);
    const pager::Point currentView = session.viewport().layout().documentToPageView(_dragPage, point);
    switch (_gesture) {
        case PagerGestureHandle: {
            if (_liveNoteId.value == 0) {
                if (const pager::Annotation *selected = session.selectedAnnotation()) {
                    [self beginLiveNote:selected->id];
                }
            }
            [self applyHandle:_editHandle from:_dragStart to:point];
            _geometryDirty = YES;
            if (_editingId.value != 0) {
                [_host canvasSyncTextEditor];
            }
            [self updateChrome];
            [self refreshLiveNote];
            break;
        }
        case PagerGestureTextSelection:
            if (_selectingFromPointer && std::hypot(point.x - _dragStart.x, point.y - _dragStart.y) < 2 / [self zoom]) {
                break;
            }
            session.setSelection([_document.source selectionOnPage:_dragPage
                                                          fromUser:pager::PageViewToUser(*geometry, startView)
                                                            toUser:pager::PageViewToUser(*geometry, currentView)]);
            [self updateSelectionLayers];
            if (_tappedNote && !session.selection().quads.empty() && session.selectedNote().value != 0) {
                // The press landed on markup but became a text drag: the text selection wins.
                session.setSelectedNote({});
                [self updateChrome];
                [_host canvasSelectionChanged];
            }
            break;
        case PagerGestureShape:
            session.setShapeDraft(ShapeKindFor(session.tool()), _dragPage, startView, currentView);
            [self refreshLiveDraft];
            break;
        case PagerGestureEraser:
            [self eraseTo:point];
            break;
        default:
            break;
    }
}

- (void)finishEraser {
    if (_gesture != PagerGestureEraser) {
        return;
    }
    _document.session.notes().endGroup();
}

- (void)performTapAt:(pager::Point)point {
    pager::DocumentSession &session = _document.session;
    if ([self clearTextSelection]) {
        return;
    }
    if (session.selectedNote().value != 0) {
        session.setSelectedNote({});
        [self updateChrome];
        [_host canvasSelectionChanged];
        return;
    }
    const pager::PageGeometry *geometry = session.viewport().geometry(_dragPage);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point pageView = session.viewport().layout().documentToPageView(_dragPage, point);
    const pager::LinkHit link = [_document.source linkOnPage:_dragPage atUser:pager::PageViewToUser(*geometry, pageView)];
    if (link.found) {
        [_host canvasOpenLink:link];
    } else {
        [_host canvasBackgroundTapped];
    }
}

- (void)endGestureAt:(pager::Point)point {
    const PagerGestureKind gesture = _gesture;
    if (_document == nil || gesture == PagerGestureNone) {
        _gesture = PagerGestureNone;
        return;
    }
    [_host canvasSetPanSuspended:NO];
    pager::DocumentSession &session = _document.session;
    const pager::PageGeometry *geometry = session.viewport().geometry(_dragPage);
    const double moved = std::hypot(point.x - _dragStart.x, point.y - _dragStart.y) * [self zoom];
    const pager::Point endView = session.viewport().layout().documentToPageView(_dragPage, point);
    const pager::Point startView = session.viewport().layout().documentToPageView(_dragPage, _dragStart);
    const pager::Tool tool = session.tool();
    BOOL editsText = NO;
    switch (gesture) {
        case PagerGestureHandle: {
            const pager::Annotation *selected = session.selectedAnnotation();
            const pager::AnnotationId identifier = selected == nullptr ? pager::AnnotationId{} : selected->id;
            const bool tappedText = selected != nullptr && selected->kind == pager::AnnotationKind::FreeText;
            if (identifier.value != 0) {
                session.notes().endEdit(identifier);
            }
            [self endLiveNote];
            // Touch: tapping a selected text box edits it. Mouse: that takes a double click.
            if (!_geometryDirty && moved <= 10 && tappedText && !_pointerSelectsText && !_tappedNote) {
                [_host canvasEditNote:identifier isNew:NO];
            }
            break;
        }
        case PagerGestureTap:
            if (!_tappedNote && moved <= 12) {
                [self performTapAt:point];
            }
            break;
        case PagerGestureTextSelection:
            if (_selectingFromPointer) {
                if (moved <= 3 && session.selection().quads.empty() && !_tappedNote) {
                    [self performTapAt:point];
                }
                break;
            }
            if (IsMarkupTool(tool) && !session.selection().quads.empty()) {
                const pager::ToolStyle style = session.activeStyle();
                const std::size_t before = session.notes().annotations().size();
                session.addMarkup(MarkupKindFor(tool), session.selection(), style.color);
                session.clearSelection();
                [self updateSelectionLayers];
                [self holdNotesFrom:before];
            }
            break;
        case PagerGestureShape: {
            const pager::ToolStyle style = session.activeStyle();
            [self invalidateLive:[self documentRectForDraft]];
            session.clearShapeDraft();
            _liveDraftRect = {};
            // A tap is not a shape.
            if (geometry != nullptr && std::hypot(endView.x - startView.x, endView.y - startView.y) >= 3) {
                const pager::AnnotationId identifier =
                    session.addShape(ShapeKindFor(tool), _dragPage, *geometry, startView, endView, style.color, style.lineWidth);
                [self holdNoteUntilRendered:identifier];
            }
            [_host canvasLiveContentChanged];
            break;
        }
        case PagerGestureTextBox: {
            if (geometry == nullptr) {
                break;
            }
            const pager::ToolStyle style = session.activeStyle();
            const pager::AnnotationId identifier =
                session.addTextNote(_dragPage, *geometry, endView, "", style.color, style.fontSize);
            session.setSelectedNote(identifier);
            [self updateChrome];
            [_host canvasSelectionChanged];
            [_host canvasEditNote:identifier isNew:YES];
            editsText = YES;
            break;
        }
        case PagerGestureEraser:
            [self finishEraser];
            break;
        case PagerGestureInk: {
            if (geometry == nullptr || !session.pen().active()) {
                session.pen().cancel();
                break;
            }
            const pager::Annotation style = pager::LiveStrokeStyle(session);
            const pager::Rect tail = [self liveTailBounds].united(_liveTail);
            const pager::AnnotationId identifier =
                session.commitPen(_dragPage, *geometry, style.color, style.lineWidth, style.pressure);
            _liveTail = {};
            [self invalidateLive:tail];
            [self holdNoteUntilRendered:identifier];
            break;
        }
        default:
            break;
    }
    _gesture = PagerGestureNone;
    _editHandle = -1;
    _dragPage = -1;
    if (session.notes().revision() != _revisionAtBegin && !editsText) {
        [_document saveNotes];
        [_host canvasNotesChanged];
    }
    [self contentDidChange];
}

- (void)cancelGesture {
    const PagerGestureKind gesture = _gesture;
    _gesture = PagerGestureNone;
    if (_document == nil || gesture == PagerGestureNone) {
        return;
    }
    pager::DocumentSession &session = _document.session;
    if (gesture == PagerGestureHandle) {
        if (const pager::Annotation *selected = session.selectedAnnotation()) {
            session.notes().endEdit(selected->id);
        }
        [self endLiveNote];
    }
    if (gesture == PagerGestureEraser) {
        session.notes().endGroup();
    }
    [self invalidateLive:[self documentRectForDraft].united([self liveTailBounds]).united(_liveTail)];
    session.clearShapeDraft();
    session.pen().cancel();
    _liveTail = {};
    _liveDraftRect = {};
    _editHandle = -1;
    _dragPage = -1;
    [_host canvasSetPanSuspended:NO];
    if (session.notes().revision() != _revisionAtBegin) {
        [_document saveNotes];
        [_host canvasNotesChanged];
    }
    [_host canvasLiveContentChanged];
    [self contentDidChange];
}

#pragma mark - Diagnostics

- (NSUInteger)tileLayerCount {
    return _pdfLayers.size();
}

- (NSUInteger)annotationLayerCount {
    return _annotationLayers.size();
}

@end
