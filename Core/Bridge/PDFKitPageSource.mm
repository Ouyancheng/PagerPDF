#import "PDFKitPageSource.h"

#include "OverlayRenderer.h"

#include <PDFKit/PDFKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>

namespace {

constexpr int kRasterLanes = 2;

NSString *BareAnnotationType(NSString *type) {
    if (type.length > 0 && [type characterAtIndex:0] == '/') {
        return [type substringFromIndex:1];
    }
    return type ?: @"";
}

BOOL AnnotationTypesMatch(NSString *type, NSString *expected) {
    return [BareAnnotationType(type) isEqualToString:BareAnnotationType(expected)];
}

NSError *PagerError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"PagerPDF" code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

pager::Point PDFKitToUser(const pager::PageGeometry &page, CGPoint point) {
    const pager::Size displayed = pager::DisplayedSize(page);
    const pager::Point pageView{point.x, displayed.height - point.y};
    return pager::PageViewToUser(page, pageView);
}

CGPoint UserToPDFKit(const pager::PageGeometry &page, pager::Point user) {
    const pager::Size displayed = pager::DisplayedSize(page);
    const pager::Point pageView = pager::UserToPageView(page, user);
    return CGPointMake(pageView.x, displayed.height - pageView.y);
}

pager::Color ColorFromPlatform(PDFKitPlatformColor *color) {
    if (color == nil || color.CGColor == nullptr) {
        return {};
    }
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef converted = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, color.CGColor, nullptr);
    CGColorSpaceRelease(srgb);
    if (converted == nullptr) {
        return {};
    }
    const CGFloat *components = CGColorGetComponents(converted);
    const size_t count = CGColorGetNumberOfComponents(converted);
    pager::Color result{0, 0, 0, 1};
    if (count >= 4) {
        result = pager::Color{static_cast<float>(components[0]), static_cast<float>(components[1]),
                              static_cast<float>(components[2]), static_cast<float>(components[3])};
    } else if (count == 2) {
        result = pager::Color{static_cast<float>(components[0]), static_cast<float>(components[0]),
                              static_cast<float>(components[0]), static_cast<float>(components[1])};
    }
    CGColorRelease(converted);
    return result;
}

BOOL PointIsFinite(pager::Point point) {
    return std::isfinite(point.x) && std::isfinite(point.y);
}

BOOL CGPointIsFinite(CGPoint point) {
    return std::isfinite(point.x) && std::isfinite(point.y);
}

BOOL CGRectIsUsable(CGRect bounds) {
    if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds) || CGRectIsInfinite(bounds)) {
        return NO;
    }
    return std::isfinite(bounds.origin.x) && std::isfinite(bounds.origin.y) && std::isfinite(bounds.size.width) &&
           std::isfinite(bounds.size.height) && bounds.size.width <= 20000 && bounds.size.height <= 20000;
}

CGPoint PointFromValue(NSValue *value) {
    if (![value isKindOfClass:[NSValue class]]) {
        return CGPointZero;
    }
#if TARGET_OS_IPHONE
    return value.CGPointValue;
#else
    return value.pointValue;
#endif
}

pager::Quad QuadFromPDFRect(const pager::PageGeometry &page, CGRect rect) {
    // Internal corner order: bottom-left, bottom-right, top-right, top-left (text space).
    const pager::Point corners[4] = {
        PDFKitToUser(page, CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect))),
        PDFKitToUser(page, CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect))),
        PDFKitToUser(page, CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))),
        PDFKitToUser(page, CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect))),
    };
    pager::Quad quad;
    for (int index = 0; index < 4; ++index) {
        quad.v[index] = corners[index];
    }
    return quad;
}

BOOL IsImportableAnnotation(PDFAnnotation *annotation) {
    if (AnnotationTypesMatch(annotation.type, PDFAnnotationSubtypeWidget) || annotation.destination != nil ||
        annotation.URL != nil) {
        return NO;
    }
    NSString *type = annotation.type;
    return AnnotationTypesMatch(type, PDFAnnotationSubtypeHighlight) ||
           AnnotationTypesMatch(type, PDFAnnotationSubtypeUnderline) ||
           AnnotationTypesMatch(type, PDFAnnotationSubtypeStrikeOut) ||
           AnnotationTypesMatch(type, PDFAnnotationSubtypeSquare) ||
           AnnotationTypesMatch(type, PDFAnnotationSubtypeCircle) ||
           AnnotationTypesMatch(type, PDFAnnotationSubtypeLine) ||
           AnnotationTypesMatch(type, PDFAnnotationSubtypeFreeText) ||
           AnnotationTypesMatch(type, PDFAnnotationSubtypeText) || AnnotationTypesMatch(type, PDFAnnotationSubtypeInk);
}

pager::AnnotationKind KindForAnnotation(PDFAnnotation *annotation) {
    NSString *type = annotation.type;
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeHighlight)) {
        return pager::AnnotationKind::Highlight;
    }
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeUnderline)) {
        return pager::AnnotationKind::Underline;
    }
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeStrikeOut)) {
        return pager::AnnotationKind::StrikeOut;
    }
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeSquare)) {
        return pager::AnnotationKind::Square;
    }
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeCircle)) {
        return pager::AnnotationKind::Circle;
    }
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeLine)) {
        return pager::AnnotationKind::Line;
    }
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeFreeText) || AnnotationTypesMatch(type, PDFAnnotationSubtypeText)) {
        return pager::AnnotationKind::FreeText;
    }
    if (AnnotationTypesMatch(type, PDFAnnotationSubtypeInk)) {
        return pager::AnnotationKind::Ink;
    }
    return pager::AnnotationKind::Square;
}

CGPathRef PathOf(id path) {
#if TARGET_OS_IPHONE
    return [path isKindOfClass:[UIBezierPath class]] ? ((UIBezierPath *)path).CGPath : nullptr;
#else
    return [path isKindOfClass:[NSBezierPath class]] ? ((NSBezierPath *)path).CGPath : nullptr;
#endif
}

pager::Rect RectFrom(CGRect rect) { return pager::Rect{rect.origin.x, rect.origin.y, rect.size.width, rect.size.height}; }

void DrawPDFPage(PDFPage *page, CGContextRef context, double pageWidth, double pageHeight) {
    // drawWithBox: applies the page's /Rotate, so the drawn footprint is the *displayed*
    // size. Scaling by the unrotated box would stretch rotated non-square pages.
    const CGRect bounds = [page boundsForBox:kPDFDisplayBoxCropBox];
    const NSInteger rotation = ((page.rotation % 360) + 360) % 360;
    const bool swapped = rotation == 90 || rotation == 270;
    const double drawnWidth = swapped ? bounds.size.height : bounds.size.width;
    const double drawnHeight = swapped ? bounds.size.width : bounds.size.height;
    if (drawnWidth > 0 && drawnHeight > 0) {
        CGContextScaleCTM(context, pageWidth / drawnWidth, pageHeight / drawnHeight);
    }
    [page drawWithBox:kPDFDisplayBoxCropBox toContext:context];
}

}  // namespace

namespace pager {

// Each lane owns a private PDFDocument so render threads never share PDFKit state with each
// other or with the main thread.
class PDFKitRasterSource final : public PageRasterSource {
public:
    struct Lane {
        std::mutex mutex;
        PDFDocument *__strong document = nil;
    };

    void drawPage(int index, CGContextRef context, double pageWidth, double pageHeight) override {
        if (lanes.empty()) {
            return;
        }
        const std::size_t start = next.fetch_add(1) % lanes.size();
        Lane *lane = nullptr;
        std::unique_lock<std::mutex> lock;
        for (std::size_t offset = 0; offset < lanes.size() && lane == nullptr; ++offset) {
            Lane *candidate = lanes[(start + offset) % lanes.size()].get();
            std::unique_lock<std::mutex> attempt(candidate->mutex, std::try_to_lock);
            if (attempt.owns_lock()) {
                lane = candidate;
                lock = std::move(attempt);
            }
        }
        if (lane == nullptr) {
            lane = lanes[start].get();
            lock = std::unique_lock<std::mutex>(lane->mutex);
        }
        @autoreleasepool {
            PDFDocument *document = lane->document;
            if (document == nil || index < 0 || index >= static_cast<int>(document.pageCount)) {
                return;
            }
            PDFPage *page = [document pageAtIndex:static_cast<NSUInteger>(index)];
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, 0, pageHeight);
            CGContextScaleCTM(context, 1, -1);
            DrawPDFPage(page, context, pageWidth, pageHeight);
            CGContextRestoreGState(context);
        }
    }

    std::vector<std::unique_ptr<Lane>> lanes;
    std::atomic<std::size_t> next{0};
};

}  // namespace pager

@implementation PDFKitPageSource {
    std::unique_ptr<pager::PDFKitRasterSource> _raster;
    PDFDocument *_document;
    NSURL *_url;
    NSData *_data;
    NSString *_password;
    std::vector<pager::PageGeometry> _geometries;
    dispatch_queue_t _searchQueue;
    PDFDocument *_searchDocument;
    std::atomic<std::uint64_t> _searchGeneration;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _raster = std::make_unique<pager::PDFKitRasterSource>();
        _searchQueue = dispatch_queue_create("pager.search", DISPATCH_QUEUE_SERIAL);
        _searchGeneration = 0;
    }
    return self;
}

- (pager::PageRasterSource *)rasterSource {
    return _raster.get();
}

- (PDFDocument *)newPrivateDocument {
    PDFDocument *document = nil;
    if (_url != nil) {
        document = [[PDFDocument alloc] initWithURL:_url];
    }
    if (document == nil && _data != nil) {
        document = [[PDFDocument alloc] initWithData:_data];
    }
    if (document.isLocked) {
        [document unlockWithPassword:_password ?: @""];
    }
    return document;
}

- (BOOL)openURL:(NSURL *)url password:(NSString *)password error:(NSError **)error {
    PDFDocument *document = [[PDFDocument alloc] initWithURL:url];
    return [self adoptDocument:document url:url data:nil password:password error:error];
}

- (BOOL)openData:(NSData *)data error:(NSError **)error {
    PDFDocument *document = [[PDFDocument alloc] initWithData:data];
    return [self adoptDocument:document url:nil data:data password:nil error:error];
}

- (BOOL)adoptDocument:(PDFDocument *)document
                  url:(NSURL *)url
                 data:(NSData *)data
             password:(NSString *)password
                error:(NSError **)error {
    if (document == nil) {
        if (error != nil) {
            *error = PagerError(@"The file is not a PDF document.", 1);
        }
        return NO;
    }
    if (document.isLocked && ![document unlockWithPassword:password ?: @""]) {
        if (error != nil) {
            *error = PagerError(@"The PDF is locked.", 2);
        }
        return NO;
    }
    [self cancelSearch];
    _document = document;
    _url = url;
    _data = data;
    _password = [password copy];
    _searchDocument = nil;
    _geometries.clear();
    for (NSInteger index = 0; index < static_cast<NSInteger>(document.pageCount); ++index) {
        _geometries.push_back([self computeGeometryAtIndex:index]);
    }
    std::vector<std::unique_ptr<pager::PDFKitRasterSource::Lane>> lanes;
    for (int index = 0; index < kRasterLanes; ++index) {
        auto lane = std::make_unique<pager::PDFKitRasterSource::Lane>();
        lane->document = [self newPrivateDocument];
        if (lane->document == nil) {
            continue;
        }
        lanes.push_back(std::move(lane));
    }
    // Swap lanes under each old lane's lock so no render is mid-flight on a lane being freed.
    for (auto &lane : _raster->lanes) {
        lane->mutex.lock();
    }
    std::vector<std::unique_ptr<pager::PDFKitRasterSource::Lane>> previous = std::move(_raster->lanes);
    _raster->lanes = std::move(lanes);
    for (auto &lane : previous) {
        lane->mutex.unlock();
    }
    return YES;
}

- (NSInteger)pageCount {
    return static_cast<NSInteger>(_geometries.size());
}

- (pager::PageGeometry)computeGeometryAtIndex:(NSInteger)index {
    pager::PageGeometry geometry;
    geometry.index = static_cast<int>(index);
    geometry.stableKey = std::to_string(index);
    PDFDocument *document = _document;
    if (document == nil || index < 0 || index >= static_cast<NSInteger>(document.pageCount)) {
        return geometry;
    }
    PDFPage *page = [document pageAtIndex:static_cast<NSUInteger>(index)];
    geometry.label = page.label.UTF8String ?: "";
    CGPDFPageRef cgPage = page.pageRef;
    if (cgPage != nullptr) {
        const CGRect media = CGPDFPageGetBoxRect(cgPage, kCGPDFMediaBox);
        const CGRect crop = CGPDFPageGetBoxRect(cgPage, kCGPDFCropBox);
        geometry.mediaBox = pager::Rect{media.origin.x, media.origin.y, media.size.width, media.size.height};
        geometry.cropBox = pager::Rect{crop.origin.x, crop.origin.y, crop.size.width, crop.size.height};
        geometry.rotation = pager::RotationFromDegrees(CGPDFPageGetRotationAngle(cgPage));
    } else {
        const CGRect bounds = [page boundsForBox:kPDFDisplayBoxCropBox];
        geometry.mediaBox = pager::Rect{0, 0, bounds.size.width, bounds.size.height};
        geometry.cropBox = geometry.mediaBox;
        geometry.rotation = pager::RotationFromDegrees(static_cast<int>(page.rotation));
    }
    if (geometry.cropBox.width <= 0 || geometry.cropBox.height <= 0) {
        geometry.cropBox = pager::Rect{0, 0, 612, 792};
        geometry.mediaBox = geometry.cropBox;
    }
    return geometry;
}

- (pager::PageGeometry)geometryAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_geometries.size())) {
        pager::PageGeometry geometry;
        geometry.index = static_cast<int>(index);
        geometry.stableKey = std::to_string(index);
        return geometry;
    }
    return _geometries[static_cast<std::size_t>(index)];
}

- (void)appendQuadsFromSelection:(PDFSelection *)selection
                          onPage:(PDFPage *)page
                        document:(PDFDocument *)document
                            into:(pager::TextSelection *)result {
    if (selection == nil || page == nil || document == nil || result == nullptr) {
        return;
    }
    const NSInteger index = [document indexForPage:page];
    if (index == NSNotFound || index < 0 || index >= static_cast<NSInteger>(_geometries.size())) {
        return;
    }
    CGRect bounds = CGRectNull;
    @try {
        bounds = [selection boundsForPage:page];
    } @catch (__unused NSException *exception) {
        return;
    }
    if (!CGRectIsUsable(bounds)) {
        return;
    }
    const pager::PageGeometry &geometry = _geometries[static_cast<std::size_t>(index)];
    pager::SelectionQuad quad;
    quad.pageIndex = static_cast<int>(index);
    quad.quad = QuadFromPDFRect(geometry, bounds);
    result->quads.push_back(quad);
}

- (pager::TextSelection)selectionFromPDF:(PDFSelection *)selection document:(PDFDocument *)document {
    pager::TextSelection result;
    if (selection == nil || document == nil) {
        return result;
    }
    NSArray<PDFPage *> *pages = nil;
    // PDFSelection can raise on empty or stale ranges after a zoom.
    @try {
        NSString *string = selection.string;
        if (string.length > 0) {
            const char *utf8 = string.UTF8String;
            result.text = utf8 != nullptr ? utf8 : "";
        }
        pages = selection.pages;
        for (PDFSelection *line in selection.selectionsByLine) {
            NSArray<PDFPage *> *linePages = line.pages.count > 0 ? line.pages : pages;
            for (PDFPage *page in linePages) {
                [self appendQuadsFromSelection:line onPage:page document:document into:&result];
            }
        }
    } @catch (__unused NSException *exception) {
        result.quads.clear();
    }
    if (result.quads.empty()) {
        for (PDFPage *page in pages) {
            [self appendQuadsFromSelection:selection onPage:page document:document into:&result];
        }
    }
    return result;
}

- (pager::TextSelection)selectionOnPage:(NSInteger)page fromUser:(pager::Point)start toUser:(pager::Point)end {
    PDFDocument *document = _document;
    if (document == nil || page < 0 || page >= static_cast<NSInteger>(_geometries.size())) {
        return {};
    }
    if (!PointIsFinite(start) || !PointIsFinite(end)) {
        return {};
    }
    const pager::PageGeometry &geometry = _geometries[static_cast<std::size_t>(page)];
    PDFPage *pdfPage = [document pageAtIndex:static_cast<NSUInteger>(page)];
    if (pdfPage == nil) {
        return {};
    }
    const CGPoint startPoint = UserToPDFKit(geometry, start);
    const CGPoint endPoint = UserToPDFKit(geometry, end);
    if (!CGPointIsFinite(startPoint) || !CGPointIsFinite(endPoint)) {
        return {};
    }
    PDFSelection *selection = nil;
    @try {
        selection = [document selectionFromPage:pdfPage atPoint:startPoint toPage:pdfPage atPoint:endPoint];
    } @catch (__unused NSException *exception) {
        return {};
    }
    return [self selectionFromPDF:selection document:document];
}

- (pager::TextSelection)selectionForWordOnPage:(NSInteger)page atUser:(pager::Point)point {
    PDFDocument *document = _document;
    if (document == nil || page < 0 || page >= static_cast<NSInteger>(_geometries.size())) {
        return {};
    }
    if (!PointIsFinite(point)) {
        return {};
    }
    const pager::PageGeometry &geometry = _geometries[static_cast<std::size_t>(page)];
    PDFPage *pdfPage = [document pageAtIndex:static_cast<NSUInteger>(page)];
    if (pdfPage == nil) {
        return {};
    }
    const CGPoint pdfPoint = UserToPDFKit(geometry, point);
    if (!CGPointIsFinite(pdfPoint)) {
        return {};
    }
    PDFSelection *selection = nil;
    @try {
        selection = [pdfPage selectionForWordAtPoint:pdfPoint];
    } @catch (__unused NSException *exception) {
        return {};
    }
    return [self selectionFromPDF:selection document:document];
}

- (std::vector<pager::TextSelection>)hitsForQuery:(NSString *)query
                                         document:(PDFDocument *)document
                                       generation:(std::uint64_t)generation {
    std::vector<pager::TextSelection> hits;
    if (query.length == 0 || document == nil) {
        return hits;
    }
    NSArray<PDFSelection *> *found = [document findString:query withOptions:NSCaseInsensitiveSearch];
    hits.reserve(found.count);
    for (PDFSelection *selection in found) {
        if (generation != 0 && generation != _searchGeneration.load()) {
            return {};
        }
        hits.push_back([self selectionFromPDF:selection document:document]);
    }
    return hits;
}

- (std::vector<pager::TextSelection>)findString:(NSString *)query {
    return [self hitsForQuery:query document:_document generation:0];
}

- (void)findString:(NSString *)query completion:(void (^)(std::vector<pager::TextSelection> hits))completion {
    const std::uint64_t generation = ++_searchGeneration;
    NSString *copy = [query copy];
    __weak PDFKitPageSource *weakSelf = self;
    dispatch_async(_searchQueue, ^{
        PDFKitPageSource *strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf->_searchGeneration.load()) {
            return;
        }
        if (strongSelf->_searchDocument == nil) {
            strongSelf->_searchDocument = [strongSelf newPrivateDocument];
        }
        auto hits = std::make_shared<std::vector<pager::TextSelection>>(
            [strongSelf hitsForQuery:copy document:strongSelf->_searchDocument generation:generation]);
        dispatch_async(dispatch_get_main_queue(), ^{
            PDFKitPageSource *mainSelf = weakSelf;
            if (mainSelf == nil || generation != mainSelf->_searchGeneration.load()) {
                return;
            }
            completion(std::move(*hits));
        });
    });
}

- (void)cancelSearch {
    ++_searchGeneration;
}

- (pager::OutlineItem)itemFromOutline:(PDFOutline *)node {
    pager::OutlineItem item;
    item.title = node.label.UTF8String ?: "";
    PDFDestination *destination = node.destination;
    if (destination == nil && [node.action isKindOfClass:[PDFActionGoTo class]]) {
        destination = ((PDFActionGoTo *)node.action).destination;
    }
    if (destination.page != nil) {
        const NSInteger index = [_document indexForPage:destination.page];
        item.pageIndex = static_cast<int>(index);
        const pager::PageGeometry geometry = [self geometryAtIndex:index];
        item.point = PDFKitToUser(geometry, destination.point);
    }
    for (NSUInteger child = 0; child < node.numberOfChildren; ++child) {
        item.children.push_back([self itemFromOutline:[node childAtIndex:child]]);
    }
    return item;
}

- (std::vector<pager::OutlineItem>)outlineItems {
    std::vector<pager::OutlineItem> items;
    PDFOutline *root = _document.outlineRoot;
    if (root == nil) {
        return items;
    }
    for (NSUInteger index = 0; index < root.numberOfChildren; ++index) {
        items.push_back([self itemFromOutline:[root childAtIndex:index]]);
    }
    return items;
}

- (pager::LinkHit)linkOnPage:(NSInteger)page atUser:(pager::Point)point {
    pager::LinkHit hit;
    PDFDocument *document = _document;
    if (document == nil || page < 0 || page >= static_cast<NSInteger>(_geometries.size())) {
        return hit;
    }
    const pager::PageGeometry &geometry = _geometries[static_cast<std::size_t>(page)];
    PDFPage *pdfPage = [document pageAtIndex:static_cast<NSUInteger>(page)];
    const CGPoint pdfPoint = UserToPDFKit(geometry, point);
    for (PDFAnnotation *annotation in pdfPage.annotations) {
        if (!CGRectContainsPoint(annotation.bounds, pdfPoint)) {
            continue;
        }
        if (annotation.URL == nil && annotation.destination == nil) {
            continue;
        }
        hit.found = YES;
        if (annotation.URL != nil) {
            hit.url = annotation.URL.absoluteString.UTF8String ?: "";
        }
        if (annotation.destination.page != nil) {
            hit.hasDestination = true;
            hit.pageIndex = static_cast<int>([document indexForPage:annotation.destination.page]);
            const pager::PageGeometry destinationPage = [self geometryAtIndex:hit.pageIndex];
            hit.point = PDFKitToUser(destinationPage, annotation.destination.point);
        }
        return hit;
    }
    return hit;
}

- (std::vector<pager::Annotation>)importAnnotations {
    std::vector<pager::Annotation> imported;
    PDFDocument *document = _document;
    if (document == nil) {
        return imported;
    }
    for (NSUInteger index = 0; index < document.pageCount && index < _geometries.size(); ++index) {
        PDFPage *page = [document pageAtIndex:index];
        const pager::PageGeometry &geometry = _geometries[index];
        for (PDFAnnotation *annotation in page.annotations) {
            if (!IsImportableAnnotation(annotation)) {
                continue;
            }
            pager::Annotation note;
            note.kind = KindForAnnotation(annotation);
            note.pageIndex = static_cast<int>(index);
            note.stableKey = geometry.stableKey;
            note.color = ColorFromPlatform(annotation.color);
            note.contents = annotation.contents.UTF8String ?: "";
            note.lineWidth = static_cast<float>(annotation.border.lineWidth);
            const CGRect bounds = annotation.bounds;
            // PDFKit reports quad points, line ends and ink paths relative to the bounds origin.
            const CGPoint origin = bounds.origin;
            auto absolute = [&](CGPoint relative) {
                return PDFKitToUser(geometry, CGPointMake(origin.x + relative.x, origin.y + relative.y));
            };
            const pager::Point minUser = PDFKitToUser(geometry, CGPointMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds)));
            const pager::Point maxUser = PDFKitToUser(geometry, CGPointMake(CGRectGetMaxX(bounds), CGRectGetMaxY(bounds)));
            note.bounds = pager::BoundsOfPoints(minUser, maxUser);
            if (note.kind == pager::AnnotationKind::Line) {
                note.lineStart = absolute(annotation.startPoint);
                note.lineEnd = absolute(annotation.endPoint);
            }
            NSArray<NSValue *> *quads = annotation.quadrilateralPoints;
            for (NSUInteger pointIndex = 0; pointIndex + 3 < quads.count; pointIndex += 4) {
                // File order is top-left, top-right, bottom-left, bottom-right; the model
                // wants bottom-left, bottom-right, top-right, top-left.
                const pager::Point topLeft = absolute(PointFromValue(quads[pointIndex]));
                const pager::Point topRight = absolute(PointFromValue(quads[pointIndex + 1]));
                const pager::Point bottomLeft = absolute(PointFromValue(quads[pointIndex + 2]));
                const pager::Point bottomRight = absolute(PointFromValue(quads[pointIndex + 3]));
                pager::Quad quad;
                quad.v[0] = bottomLeft;
                quad.v[1] = bottomRight;
                quad.v[2] = topRight;
                quad.v[3] = topLeft;
                note.quads.push_back(quad);
            }
            if (note.quads.empty() && (note.kind == pager::AnnotationKind::Highlight ||
                                       note.kind == pager::AnnotationKind::Underline ||
                                       note.kind == pager::AnnotationKind::StrikeOut)) {
                note.quads.push_back(QuadFromPDFRect(geometry, bounds));
            }
            if (note.kind != pager::AnnotationKind::Ink) {
                imported.push_back(std::move(note));
                continue;
            }
            // One model annotation per ink path; joining them would draw strokes between paths.
            for (id path in annotation.paths) {
                CGPathRef cgPath = PathOf(path);
                if (cgPath == nullptr) {
                    continue;
                }
                pager::Annotation stroke = note;
                pager::Annotation *target = &stroke;
                CGPathApplyWithBlock(cgPath, ^(const CGPathElement *element) {
                    if (element->type == kCGPathElementCloseSubpath) {
                        return;
                    }
                    const int count = element->type == kCGPathElementAddCurveToPoint
                                          ? 3
                                          : (element->type == kCGPathElementAddQuadCurveToPoint ? 2 : 1);
                    const CGPoint end = element->points[count - 1];
                    const pager::Point user = absolute(end);
                    pager::InkSample sample;
                    sample.x = user.x;
                    sample.y = user.y;
                    sample.force = 1;
                    target->samples.push_back(sample);
                });
                if (!stroke.samples.empty()) {
                    imported.push_back(std::move(stroke));
                }
            }
        }
    }
    return imported;
}

- (BOOL)writeFlattenedSession:(const pager::DocumentSession &)session toURL:(NSURL *)url error:(NSError **)error {
    return [self writeFlattenedNotes:session.notes().annotations() toURL:url error:error];
}

- (BOOL)writeFlattenedNotes:(const std::vector<pager::Annotation> &)notes toURL:(NSURL *)url error:(NSError **)error {
    PDFDocument *document = [self newPrivateDocument];
    if (document == nil || _geometries.empty()) {
        if (error != nil) {
            *error = PagerError(@"There is no open document to export.", 3);
        }
        return NO;
    }
    std::vector<std::vector<const pager::Annotation *>> byPage(_geometries.size());
    for (const pager::Annotation &note : notes) {
        if (note.pageIndex >= 0 && static_cast<std::size_t>(note.pageIndex) < byPage.size()) {
            byPage[static_cast<std::size_t>(note.pageIndex)].push_back(&note);
        }
    }
    const pager::Size firstSize = pager::DisplayedSize(_geometries.front());
    CGRect firstMedia = CGRectMake(0, 0, std::max(1.0, firstSize.width), std::max(1.0, firstSize.height));
    CGContextRef context = CGPDFContextCreateWithURL((__bridge CFURLRef)url, &firstMedia, nullptr);
    if (context == nullptr) {
        if (error != nil) {
            *error = PagerError(@"The flattened PDF could not be written.", 4);
        }
        return NO;
    }
    pager::InkPathCache cache;
    const NSUInteger pageCount = std::min<NSUInteger>(document.pageCount, _geometries.size());
    for (NSUInteger index = 0; index < pageCount; ++index) {
        @autoreleasepool {
            const pager::PageGeometry &geometry = _geometries[index];
            const pager::Size displayed = pager::DisplayedSize(geometry);
            CGRect media = CGRectMake(0, 0, std::max(1.0, displayed.width), std::max(1.0, displayed.height));
            CFDataRef box = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(&media), sizeof(media));
            const void *keys[] = {kCGPDFContextMediaBox};
            const void *values[] = {box};
            CFDictionaryRef info = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                      &kCFTypeDictionaryValueCallBacks);
            CGPDFContextBeginPage(context, info);
            CFRelease(info);
            CFRelease(box);
            PDFPage *page = [document pageAtIndex:index];
            if (page != nil) {
                CGContextSaveGState(context);
                DrawPDFPage(page, context, media.size.width, media.size.height);
                CGContextRestoreGState(context);
            }
            // Same renderer and the same y-down page space as the screen tiles, so the export
            // looks exactly like what the user annotated.
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, 0, media.size.height);
            CGContextScaleCTM(context, 1, -1);
            for (const pager::Annotation *note : byPage[index]) {
                pager::DrawAnnotationInPage(context, geometry, *note, {}, &cache);
            }
            CGContextRestoreGState(context);
            CGPDFContextEndPage(context);
        }
    }
    CGPDFContextClose(context);
    CGContextRelease(context);
    return YES;
}

@end
