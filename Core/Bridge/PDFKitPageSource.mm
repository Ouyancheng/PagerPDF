#import "PDFKitPageSource.h"

#include <PDFKit/PDFKit.h>
#include <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <mutex>

namespace {

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

}  // namespace

namespace pager {

class PDFKitRasterSource final : public PageRasterSource {
public:
    void drawPage(int index, CGContextRef context, double pageWidth, double pageHeight) override {
        std::lock_guard<std::recursive_mutex> guard(mutex);
        if (document == nil || index < 0 || index >= static_cast<int>(document.pageCount)) {
            return;
        }
        PDFPage *page = [document pageAtIndex:static_cast<NSUInteger>(index)];
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 0, pageHeight);
        CGContextScaleCTM(context, 1, -1);
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
        CGContextRestoreGState(context);
    }

    std::recursive_mutex mutex;
    PDFDocument *__strong document = nil;
};

}  // namespace pager

@implementation PDFKitPageSource {
    std::unique_ptr<pager::PDFKitRasterSource> raster_;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        raster_ = std::make_unique<pager::PDFKitRasterSource>();
    }
    return self;
}

- (pager::PageRasterSource *)rasterSource {
    return raster_.get();
}

- (BOOL)openURL:(NSURL *)url password:(NSString *)password error:(NSError **)error {
    PDFDocument *document = [[PDFDocument alloc] initWithURL:url];
    return [self adoptDocument:document password:password error:error];
}

- (BOOL)openData:(NSData *)data error:(NSError **)error {
    PDFDocument *document = [[PDFDocument alloc] initWithData:data];
    return [self adoptDocument:document password:nil error:error];
}

- (BOOL)adoptDocument:(PDFDocument *)document password:(NSString *)password error:(NSError **)error {
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
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    raster_->document = document;
    return YES;
}

- (NSInteger)pageCount {
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    return raster_->document.pageCount;
}

- (pager::PageGeometry)geometryAtIndex:(NSInteger)index {
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    pager::PageGeometry geometry;
    geometry.index = static_cast<int>(index);
    geometry.stableKey = std::to_string(index);
    PDFDocument *document = raster_->document;
    if (document == nil || index < 0 || index >= static_cast<NSInteger>(document.pageCount)) {
        return geometry;
    }
    PDFPage *page = [document pageAtIndex:static_cast<NSUInteger>(index)];
    geometry.label = page.label.UTF8String ?: "";
    CGPDFPageRef cgPage = CGPDFDocumentGetPage(document.documentRef, index + 1);
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

- (void)appendQuadsFromSelection:(PDFSelection *)selection
                          onPage:(PDFPage *)page
                        document:(PDFDocument *)document
                          into:(pager::TextSelection *)result {
    if (selection == nil || page == nil || document == nil || result == nullptr) {
        return;
    }
    const NSInteger index = [document indexForPage:page];
    if (index == NSNotFound || index < 0) {
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
    const pager::PageGeometry geometry = [self geometryAtIndex:index];
    pager::SelectionQuad quad;
    quad.pageIndex = static_cast<int>(index);
    quad.quad = QuadFromPDFRect(geometry, bounds);
    result->quads.push_back(quad);
}

- (pager::TextSelection)selectionFromPDF:(PDFSelection *)selection {
    pager::TextSelection result;
    PDFDocument *document = raster_->document;
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
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    PDFDocument *document = raster_->document;
    if (document == nil || page < 0 || page >= static_cast<NSInteger>(document.pageCount)) {
        return {};
    }
    if (!PointIsFinite(start) || !PointIsFinite(end)) {
        return {};
    }
    const pager::PageGeometry geometry = [self geometryAtIndex:page];
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
    return [self selectionFromPDF:selection];
}

- (pager::TextSelection)selectionForWordOnPage:(NSInteger)page atUser:(pager::Point)point {
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    PDFDocument *document = raster_->document;
    if (document == nil || page < 0 || page >= static_cast<NSInteger>(document.pageCount)) {
        return {};
    }
    if (!PointIsFinite(point)) {
        return {};
    }
    const pager::PageGeometry geometry = [self geometryAtIndex:page];
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
    return [self selectionFromPDF:selection];
}

- (std::vector<pager::TextSelection>)findString:(NSString *)query {
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    std::vector<pager::TextSelection> hits;
    if (query.length == 0 || raster_->document == nil) {
        return hits;
    }
    NSArray<PDFSelection *> *found = [raster_->document findString:query withOptions:NSCaseInsensitiveSearch];
    for (PDFSelection *selection in found) {
        hits.push_back([self selectionFromPDF:selection]);
    }
    return hits;
}

- (pager::OutlineItem)itemFromOutline:(PDFOutline *)node {
    pager::OutlineItem item;
    item.title = node.label.UTF8String ?: "";
    PDFDestination *destination = node.destination;
    if (destination == nil && [node.action isKindOfClass:[PDFActionGoTo class]]) {
        destination = ((PDFActionGoTo *)node.action).destination;
    }
    if (destination.page != nil) {
        const NSInteger index = [raster_->document indexForPage:destination.page];
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
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    std::vector<pager::OutlineItem> items;
    PDFOutline *root = raster_->document.outlineRoot;
    if (root == nil) {
        return items;
    }
    for (NSUInteger index = 0; index < root.numberOfChildren; ++index) {
        items.push_back([self itemFromOutline:[root childAtIndex:index]]);
    }
    return items;
}

- (pager::LinkHit)linkOnPage:(NSInteger)page atUser:(pager::Point)point {
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    pager::LinkHit hit;
    PDFDocument *document = raster_->document;
    if (document == nil || page < 0 || page >= static_cast<NSInteger>(document.pageCount)) {
        return hit;
    }
    const pager::PageGeometry geometry = [self geometryAtIndex:page];
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

- (pager::AnnotationKind)kindForAnnotation:(PDFAnnotation *)annotation {
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

- (std::vector<pager::Annotation>)importAnnotations {
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    std::vector<pager::Annotation> imported;
    PDFDocument *document = raster_->document;
    if (document == nil) {
        return imported;
    }
    for (NSUInteger index = 0; index < document.pageCount; ++index) {
        PDFPage *page = [document pageAtIndex:index];
        const pager::PageGeometry geometry = [self geometryAtIndex:static_cast<NSInteger>(index)];
        for (PDFAnnotation *annotation in page.annotations) {
            if (AnnotationTypesMatch(annotation.type, PDFAnnotationSubtypeWidget) || annotation.destination != nil ||
                annotation.URL != nil) {
                continue;
            }
            NSString *type = annotation.type;
            const bool known = AnnotationTypesMatch(type, PDFAnnotationSubtypeHighlight) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeUnderline) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeStrikeOut) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeSquare) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeCircle) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeLine) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeFreeText) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeText) ||
                               AnnotationTypesMatch(type, PDFAnnotationSubtypeInk);
            if (!known) {
                continue;
            }
            pager::Annotation note;
            note.kind = [self kindForAnnotation:annotation];
            note.pageIndex = static_cast<int>(index);
            note.stableKey = geometry.stableKey;
            note.color = ColorFromPlatform(annotation.color);
            note.contents = annotation.contents.UTF8String ?: "";
            note.lineWidth = static_cast<float>(annotation.border.lineWidth);
            const CGRect bounds = annotation.bounds;
            const pager::Point minUser = PDFKitToUser(geometry, CGPointMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds)));
            const pager::Point maxUser = PDFKitToUser(geometry, CGPointMake(CGRectGetMaxX(bounds), CGRectGetMaxY(bounds)));
            note.bounds = pager::BoundsOfPoints(minUser, maxUser);
            note.lineStart = PDFKitToUser(geometry, annotation.startPoint);
            note.lineEnd = PDFKitToUser(geometry, annotation.endPoint);
            NSArray<NSValue *> *quads = annotation.quadrilateralPoints;
            for (NSUInteger pointIndex = 0; pointIndex + 3 < quads.count; pointIndex += 4) {
                pager::Quad quad;
                for (int corner = 0; corner < 4; ++corner) {
                    quad.v[corner] = PDFKitToUser(geometry, PointFromValue(quads[pointIndex + corner]));
                }
                note.quads.push_back(quad);
            }
            if (note.quads.empty() && (note.kind == pager::AnnotationKind::Highlight ||
                                       note.kind == pager::AnnotationKind::Underline ||
                                       note.kind == pager::AnnotationKind::StrikeOut)) {
                note.quads.push_back(QuadFromPDFRect(geometry, bounds));
            }
            id inkList = [annotation valueForAnnotationKey:PDFAnnotationKeyInklist];
            if ([inkList isKindOfClass:[NSArray class]]) {
                for (id path in (NSArray *)inkList) {
                    if (![path isKindOfClass:[NSArray class]]) {
                        continue;
                    }
                    for (id value in (NSArray *)path) {
                        if (![value isKindOfClass:[NSValue class]]) {
                            continue;
                        }
                        const pager::Point user = PDFKitToUser(geometry, PointFromValue(value));
                        pager::InkSample sample;
                        sample.x = user.x;
                        sample.y = user.y;
                        sample.force = 1;
                        note.samples.push_back(sample);
                    }
                }
            }
            imported.push_back(std::move(note));
        }
    }
    return imported;
}

- (BOOL)writeFlattenedSession:(const pager::DocumentSession &)session toURL:(NSURL *)url error:(NSError **)error {
    std::lock_guard<std::recursive_mutex> guard(raster_->mutex);
    PDFDocument *document = raster_->document;
    if (document == nil) {
        if (error != nil) {
            *error = PagerError(@"There is no open document to export.", 3);
        }
        return NO;
    }
    PDFDocument *output = [[PDFDocument alloc] init];
    for (NSInteger index = 0; index < static_cast<NSInteger>(document.pageCount); ++index) {
        const pager::PageGeometry geometry = [self geometryAtIndex:index];
        const pager::Size displayed = pager::DisplayedSize(geometry);
        const CGRect media = CGRectMake(0, 0, std::max(1.0, displayed.width), std::max(1.0, displayed.height));
        NSMutableData *pageData = [NSMutableData data];
        CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)pageData);
        CGContextRef context = CGPDFContextCreate(consumer, &media, nullptr);
        PDFPage *page = [document pageAtIndex:static_cast<NSUInteger>(index)];
        if (context == nullptr || page == nil) {
            if (context != nullptr) {
                CGContextRelease(context);
            }
            if (consumer != nullptr) {
                CGDataConsumerRelease(consumer);
            }
            continue;
        }
        CGPDFContextBeginPage(context, nullptr);
        CGContextSaveGState(context);
        const CGRect bounds = [page boundsForBox:kPDFDisplayBoxCropBox];
        const NSInteger rotation = ((page.rotation % 360) + 360) % 360;
        const bool swapped = rotation == 90 || rotation == 270;
        const double drawnWidth = swapped ? bounds.size.height : bounds.size.width;
        const double drawnHeight = swapped ? bounds.size.width : bounds.size.height;
        if (drawnWidth > 0 && drawnHeight > 0) {
            CGContextScaleCTM(context, media.size.width / drawnWidth, media.size.height / drawnHeight);
        }
        [page drawWithBox:kPDFDisplayBoxCropBox toContext:context];
        CGContextRestoreGState(context);
        auto drawList = [&](const std::vector<pager::Annotation> &notes) {
            for (const pager::Annotation &note : notes) {
                if (note.pageIndex != index) {
                    continue;
                }
                [self drawNote:note geometry:geometry inContext:context];
            }
        };
        drawList(session.imported);
        drawList(session.notes().annotations());
        CGPDFContextEndPage(context);
        CGPDFContextClose(context);
        CGContextRelease(context);
        CGDataConsumerRelease(consumer);
        PDFDocument *single = [[PDFDocument alloc] initWithData:pageData];
        if (single.pageCount > 0) {
            [output insertPage:[single pageAtIndex:0] atIndex:output.pageCount];
        }
    }
    if (![output writeToURL:url]) {
        if (error != nil) {
            *error = PagerError(@"The flattened PDF could not be written.", 4);
        }
        return NO;
    }
    return YES;
}

- (void)drawNote:(const pager::Annotation &)note
        geometry:(const pager::PageGeometry &)geometry
       inContext:(CGContextRef)context {
    CGContextSaveGState(context);
    CGContextSetRGBStrokeColor(context, note.color.r, note.color.g, note.color.b, note.color.a == 0 ? 1 : note.color.a);
    CGContextSetRGBFillColor(context, note.color.r, note.color.g, note.color.b, note.kind == pager::AnnotationKind::Highlight ? 0.35 : note.color.a);
    CGContextSetLineWidth(context, note.lineWidth <= 0 ? 1 : note.lineWidth);
    auto up = [&](pager::Point user) { return UserToPDFKit(geometry, user); };
    if (!note.quads.empty()) {
        for (const pager::Quad &quad : note.quads) {
            CGContextBeginPath(context);
            const CGPoint first = up(quad.v[0]);
            CGContextMoveToPoint(context, first.x, first.y);
            for (int corner = 1; corner < 4; ++corner) {
                const CGPoint point = up(quad.v[corner]);
                CGContextAddLineToPoint(context, point.x, point.y);
            }
            CGContextClosePath(context);
            if (note.kind == pager::AnnotationKind::Highlight) {
                CGContextFillPath(context);
            } else if (note.kind == pager::AnnotationKind::Underline) {
                const CGPoint a = up(quad.v[0]);
                const CGPoint b = up(quad.v[1]);
                CGContextMoveToPoint(context, a.x, a.y);
                CGContextAddLineToPoint(context, b.x, b.y);
                CGContextStrokePath(context);
            } else {
                const CGPoint a = up(quad.v[0]);
                const CGPoint b = up(quad.v[1]);
                const CGPoint c = up(quad.v[3]);
                CGContextMoveToPoint(context, (a.x + c.x) * 0.5, (a.y + c.y) * 0.5);
                CGContextAddLineToPoint(context, (b.x + up(quad.v[2]).x) * 0.5, (b.y + up(quad.v[2]).y) * 0.5);
                CGContextStrokePath(context);
            }
        }
    } else if (note.kind == pager::AnnotationKind::Line || note.kind == pager::AnnotationKind::Ink) {
        CGContextBeginPath(context);
        bool moved = false;
        if (note.kind == pager::AnnotationKind::Line) {
            const CGPoint a = up(note.lineStart);
            const CGPoint b = up(note.lineEnd);
            CGContextMoveToPoint(context, a.x, a.y);
            CGContextAddLineToPoint(context, b.x, b.y);
            moved = true;
        } else {
            for (const pager::InkSample &sample : note.samples) {
                const CGPoint point = up(pager::Point{sample.x, sample.y});
                if (!moved) {
                    CGContextMoveToPoint(context, point.x, point.y);
                    moved = true;
                } else {
                    CGContextAddLineToPoint(context, point.x, point.y);
                }
            }
        }
        if (moved) {
            CGContextStrokePath(context);
        }
    } else if (note.kind == pager::AnnotationKind::Circle || note.kind == pager::AnnotationKind::Square ||
               note.kind == pager::AnnotationKind::FreeText) {
        const CGPoint a = up(pager::Point{note.bounds.x, note.bounds.y});
        const CGPoint b = up(pager::Point{note.bounds.x + note.bounds.width, note.bounds.y + note.bounds.height});
        const CGRect rect = CGRectMake(std::min(a.x, b.x), std::min(a.y, b.y), std::abs(a.x - b.x), std::abs(a.y - b.y));
        if (note.kind == pager::AnnotationKind::Circle) {
            CGContextStrokeEllipseInRect(context, rect);
        } else if (note.kind == pager::AnnotationKind::FreeText) {
            CGContextSetRGBFillColor(context, 1, 1, 1, 0.92);
            CGContextFillRect(context, rect);
            CGContextStrokeRect(context, rect);
            if (!note.contents.empty()) {
                CGContextSaveGState(context);
                CGContextTranslateCTM(context, rect.origin.x, CGRectGetMaxY(rect));
                CGContextScaleCTM(context, 1, -1);
                const CGFloat size = note.fontSize > 0 ? note.fontSize : 14;
                NSString *text = @(note.contents.c_str());
                CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), size, nullptr);
                CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                const CGFloat components[] = {note.color.r, note.color.g, note.color.b, note.color.a == 0 ? 1 : note.color.a};
                CGColorRef cgColor = CGColorCreate(colorSpace, components);
                const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
                const void *values[] = {font, cgColor};
                CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                           &kCFTypeDictionaryValueCallBacks);
                CFAttributedStringRef attributed =
                    CFAttributedStringCreate(kCFAllocatorDefault, (__bridge CFStringRef)text, attrs);
                CTFramesetterRef setter = CTFramesetterCreateWithAttributedString(attributed);
                CGPathRef path = CGPathCreateWithRect(CGRectInset(CGRectMake(0, 0, rect.size.width, rect.size.height), 6, 4), nullptr);
                CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nullptr);
                CTFrameDraw(frame, context);
                CFRelease(frame);
                CGPathRelease(path);
                CFRelease(setter);
                CFRelease(attributed);
                CFRelease(attrs);
                CGColorRelease(cgColor);
                CGColorSpaceRelease(colorSpace);
                CFRelease(font);
                CGContextRestoreGState(context);
            }
        } else {
            CGContextSetRGBFillColor(context, note.color.r, note.color.g, note.color.b, 0.85);
            CGContextFillRect(context, rect);
            CGContextStrokeRect(context, rect);
        }
    }
    CGContextRestoreGState(context);
}

@end
