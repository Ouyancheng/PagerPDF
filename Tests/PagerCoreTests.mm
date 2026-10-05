#import <XCTest/XCTest.h>
#import <PDFKit/PDFKit.h>
#import <CoreText/CoreText.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#import "AnnotationRasterizer.h"
#import "NoteArchive.h"
#import "PDFKitPageSource.h"
#import "PagerCanvasView.h"
#import "PagerDocument.h"

#include "AnnotationGeometry.hpp"
#include "DocumentSession.hpp"
#include "Geometry.hpp"
#include "Ink.hpp"
#include "Layout.hpp"
#include "NoteDocument.hpp"
#include "TileCache.hpp"
#include "Viewport.hpp"
#include "Zoom.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <thread>

namespace {

pager::PageGeometry Page(double x, double y, double width, double height, pager::PageRotation rotation) {
    pager::PageGeometry page;
    page.mediaBox = pager::Rect{x, y, width, height};
    page.cropBox = page.mediaBox;
    page.rotation = rotation;
    page.userUnit = 1;
    return page;
}

NSData *PDFWithHello(int rotation) {
    NSMutableData *data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect media = CGRectMake(0, 0, 320, 180);
    CGContextRef context = CGPDFContextCreate(consumer, &media, nullptr);
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef rotate = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &rotation);
    CFDictionarySetValue(info, CFSTR("Rotate"), rotate);
    CGPDFContextBeginPage(context, info);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, media);
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), 24, nullptr);
    CFStringRef keys[] = {kCTFontAttributeName};
    CFTypeRef values[] = {font};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, (const void **)values, 1,
                                                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef string = CFAttributedStringCreate(kCFAllocatorDefault, CFSTR("Hello"), attributes);
    CTLineRef line = CTLineCreateWithAttributedString(string);
    CGContextSetTextPosition(context, 48, 72);
    CTLineDraw(line, context);
    CFRelease(line);
    CFRelease(string);
    CFRelease(attributes);
    CFRelease(font);
    CGPDFContextEndPage(context);
    CGPDFContextClose(context);
    CGContextRelease(context);
    CGDataConsumerRelease(consumer);
    CFRelease(rotate);
    CFRelease(info);
    return data;
}

NSData *PDFWithOutline(void) {
    NSArray<NSString *> *objects = @[
        @"<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>",
        @"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        @"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 180] /Contents 6 0 R >>",
        @"<< /Type /Outlines /Count 1 /First 5 0 R /Last 5 0 R >>",
        @"<< /Title (Start) /Parent 4 0 R /Dest [3 0 R /XYZ 10 10 0] >>",
        @"<< /Length 0 >>\nstream\nendstream",
    ];
    NSMutableString *body = [NSMutableString stringWithString:@"%PDF-1.4\n"];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray arrayWithObject:@0];
    for (NSUInteger index = 0; index < objects.count; ++index) {
        [offsets addObject:@(body.length)];
        [body appendFormat:@"%lu 0 obj\n%@\nendobj\n", (unsigned long)(index + 1), objects[index]];
    }
    const NSUInteger xref = body.length;
    [body appendFormat:@"xref\n0 %lu\n", (unsigned long)(objects.count + 1)];
    [body appendString:@"0000000000 65535 f \n"];
    for (NSUInteger index = 1; index < offsets.count; ++index) {
        [body appendFormat:@"%010lu 00000 n \n", offsets[index].unsignedLongValue];
    }
    [body appendFormat:@"trailer\n<< /Size %lu /Root 1 0 R >>\nstartxref\n%lu\n%%%%EOF\n",
                       (unsigned long)(objects.count + 1), (unsigned long)xref];
    return [body dataUsingEncoding:NSASCIIStringEncoding];
}

struct WaitClient : pager::TileClient {
    std::mutex mutex;
    std::condition_variable condition;
    bool arrived = false;
    // Low-resolution base tiles render alongside the sharp ones; tests usually want one band.
    int band = -1;
    pager::TileImage image;

    void tileReady(pager::TileImage tile) override {
        std::lock_guard<std::mutex> guard(mutex);
        if (arrived || (band >= 0 && tile.key.scaleBand != band)) {
            return;
        }
        image = std::move(tile);
        arrived = true;
        condition.notify_all();
    }
};

struct BlockSource : pager::PageRasterSource {
    void drawPage(int, CGContextRef context, double pageWidth, double pageHeight) override {
        CGContextSetRGBFillColor(context, 0, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(0, pageHeight - 40, pageWidth, 40));
    }
};

bool IsBlack(const std::uint8_t *pixel) {
    return pixel[0] < 8 && pixel[1] < 8 && pixel[2] < 8 && pixel[3] > 200;
}

bool IsWhite(const std::uint8_t *pixel) {
    return pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245 && pixel[3] > 200;
}

// BGRA, premultiplied, top row first.
std::vector<std::uint8_t> Pixels(CGImageRef image) {
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    std::vector<std::uint8_t> bytes(width * height * 4, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bytes.data(), width, height, 8, width * 4, space,
                                                 static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) |
                                                     static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little));
    CGColorSpaceRelease(space);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    return bytes;
}

int CountDark(const std::vector<std::uint8_t> &pixels, int width, int minX, int minY, int maxX, int maxY) {
    int count = 0;
    for (int y = minY; y < maxY; ++y) {
        for (int x = minX; x < maxX; ++x) {
            const std::uint8_t *pixel = pixels.data() + (y * width + x) * 4;
            if (pixel[3] > 128 && pixel[0] < 110 && pixel[1] < 110 && pixel[2] < 110) {
                ++count;
            }
        }
    }
    return count;
}

bool SpinUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done() && limit.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done();
}

pager::Annotation StraightInk(double x0, double x1, double y, int samples) {
    pager::Annotation ink;
    ink.kind = pager::AnnotationKind::Ink;
    ink.pageIndex = 0;
    ink.lineWidth = 2;
    for (int index = 0; index < samples; ++index) {
        pager::InkSample sample;
        sample.x = x0 + (x1 - x0) * index / std::max(1, samples - 1);
        sample.y = y;
        sample.force = 1;
        ink.samples.push_back(sample);
    }
    ink.bounds = pager::Rect{std::min(x0, x1), y, std::fabs(x1 - x0), 1};
    return ink;
}

// Writes a one-page 400x400 PDF with hand-authored annotations, as Acrobat would store them.
NSURL *PDFWithAuthoredAnnotations(void) {
    NSArray<NSString *> *objects = @[
        @"<< /Type /Catalog /Pages 2 0 R >>",
        @"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        @"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Contents 4 0 R /Annots [5 0 R 6 0 R 7 0 R] >>",
        @"<< /Length 0 >>\nstream\nendstream",
        @"<< /Type /Annot /Subtype /Highlight /Rect [100 200 180 220] /QuadPoints [100 220 180 220 100 200 180 200] /C [1 1 0] >>",
        @"<< /Type /Annot /Subtype /Line /Rect [50 50 150 120] /L [60 60 140 110] /C [1 0 0] >>",
        @"<< /Type /Annot /Subtype /Ink /Rect [200 200 300 300] /InkList [[210 210 220 230 230 250] [260 260 280 290]] /C [0 0 1] >>",
    ];
    NSMutableString *body = [NSMutableString stringWithString:@"%PDF-1.4\n"];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    for (NSUInteger index = 0; index < objects.count; ++index) {
        [offsets addObject:@(body.length)];
        [body appendFormat:@"%lu 0 obj\n%@\nendobj\n", (unsigned long)(index + 1), objects[index]];
    }
    const NSUInteger xref = body.length;
    [body appendFormat:@"xref\n0 %lu\n0000000000 65535 f \n", (unsigned long)(objects.count + 1)];
    for (NSNumber *offset in offsets) {
        [body appendFormat:@"%010lu 00000 n \n", offset.unsignedLongValue];
    }
    [body appendFormat:@"trailer\n<< /Size %lu /Root 1 0 R >>\nstartxref\n%lu\n%%%%EOF\n",
                       (unsigned long)(objects.count + 1), (unsigned long)xref];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                                                    [NSString stringWithFormat:@"pager-authored-%@.pdf", NSUUID.UUID.UUIDString]]];
    [[body dataUsingEncoding:NSASCIIStringEncoding] writeToURL:url atomically:YES];
    return url;
}

}  // namespace

@interface PagerCoreTests : XCTestCase
@end

@implementation PagerCoreTests

- (void)testRotationZeroAndCropBox {
    pager::PageGeometry page = Page(10, 20, 100, 80, pager::PageRotation::R0);
    const pager::Size displayed = pager::DisplayedSize(page);
    XCTAssertEqual(displayed.width, 100);
    XCTAssertEqual(displayed.height, 80);
    const pager::Point topLeft = pager::UserToPageView(page, pager::Point{10, 100});
    XCTAssertEqualWithAccuracy(topLeft.x, 0, 0.001);
    XCTAssertEqualWithAccuracy(topLeft.y, 0, 0.001);
    const pager::Point bottomLeft = pager::UserToPageView(page, pager::Point{10, 20});
    XCTAssertEqualWithAccuracy(bottomLeft.x, 0, 0.001);
    XCTAssertEqualWithAccuracy(bottomLeft.y, 80, 0.001);
    const pager::Point roundTrip = pager::PageViewToUser(page, bottomLeft);
    XCTAssertEqualWithAccuracy(roundTrip.x, 10, 0.001);
    XCTAssertEqualWithAccuracy(roundTrip.y, 20, 0.001);
}

- (void)testAllRotationsMapCorners {
    const pager::PageRotation rotations[] = {pager::PageRotation::R0, pager::PageRotation::R90, pager::PageRotation::R180,
                                             pager::PageRotation::R270};
    for (pager::PageRotation rotation : rotations) {
        pager::PageGeometry page = Page(0, 0, 200, 100, rotation);
        const pager::Size displayed = pager::DisplayedSize(page);
        const pager::Point corners[] = {{0, 0}, {200, 0}, {200, 100}, {0, 100}};
        for (pager::Point corner : corners) {
            const pager::Point view = pager::UserToPageView(page, corner);
            XCTAssertGreaterThanOrEqual(view.x, -0.001);
            XCTAssertGreaterThanOrEqual(view.y, -0.001);
            XCTAssertLessThanOrEqual(view.x, displayed.width + 0.001);
            XCTAssertLessThanOrEqual(view.y, displayed.height + 0.001);
            const pager::Point user = pager::PageViewToUser(page, view);
            XCTAssertEqualWithAccuracy(user.x, corner.x, 0.001);
            XCTAssertEqualWithAccuracy(user.y, corner.y, 0.001);
        }
    }
}

- (void)testLayoutStacksPages {
    pager::PageGeometry first = Page(0, 0, 100, 200, pager::PageRotation::R0);
    pager::PageGeometry second = first;
    second.index = 1;
    pager::Layout layout;
    layout.rebuild({first, second}, 1);
    XCTAssertEqual(layout.pages().size(), 2u);
    XCTAssertEqualWithAccuracy(layout.pages()[0].frame.y, pager::Layout::kMargin, 0.001);
    XCTAssertEqualWithAccuracy(layout.pages()[1].frame.y, pager::Layout::kMargin + 200 + pager::Layout::kPageGap, 0.001);
    XCTAssertEqualWithAccuracy(layout.contentSize().height,
                              pager::Layout::kMargin * 2 + 200 + pager::Layout::kPageGap + 200, 0.001);
    XCTAssertEqual(layout.pageAt(pager::Point{layout.pages()[1].frame.x + 1, layout.pages()[1].frame.y + 1}), 1);
}

- (void)testScaleKeyTracksExactZoom {
    XCTAssertEqual(pager::ScaleKeyForZoom(1), 100);
    XCTAssertEqual(pager::ScaleKeyForZoom(2), 200);
    XCTAssertEqual(pager::ScaleKeyForZoom(1.25), 125);
}

- (void)testLayerContentsScaleTracksZoomAndScreen {
    XCTAssertEqualWithAccuracy(pager::LayerContentsScale(2, 1), 2, 0.001);
    XCTAssertEqualWithAccuracy(pager::LayerContentsScale(2, 1.25), 2.5, 0.001);
    XCTAssertEqualWithAccuracy(pager::LayerContentsScale(2, 8), 4, 0.001);
    XCTAssertEqualWithAccuracy(pager::LayerContentsScale(3, 1.2), 3.6, 0.001);
}

- (void)testSetScaleChangesTileKeyWithoutMovingLayout {
    pager::PageGeometry page = Page(0, 0, 200, 200, pager::PageRotation::R0);
    page.index = 0;
    pager::Viewport viewport;
    viewport.setScreenScale(1);
    viewport.setScale(1);
    viewport.setPages({page});
    viewport.setVisibleRect(pager::Rect{0, 0, 2000, 2000});
    const pager::Rect frameAtOne = viewport.layout().pageFrame(0);
    const std::vector<pager::TileSlot> before = viewport.visibleSlots();
    XCTAssertFalse(before.empty());
    XCTAssertEqual(before.front().key.scaleBand, 100);
    viewport.setScale(2);
    const std::vector<pager::TileSlot> after = viewport.visibleSlots();
    XCTAssertFalse(after.empty());
    XCTAssertEqual(after.front().key.scaleBand, 200);
    XCTAssertFalse(after.front().ready);
    const pager::Rect frameAtTwo = viewport.layout().pageFrame(0);
    XCTAssertEqualWithAccuracy(frameAtOne.x, frameAtTwo.x, 0.001);
    XCTAssertEqualWithAccuracy(frameAtOne.y, frameAtTwo.y, 0.001);
    XCTAssertEqualWithAccuracy(frameAtOne.width, frameAtTwo.width, 0.001);
    XCTAssertEqualWithAccuracy(frameAtOne.height, frameAtTwo.height, 0.001);
    XCTAssertEqualWithAccuracy(viewport.layout().scale(), 1, 0.001);
}

- (void)testTileDocumentFrameStaysOnThePageAcrossZoom {
    pager::PageGeometry page = Page(0, 0, 2000, 2000, pager::PageRotation::R0);
    page.index = 0;
    pager::Viewport viewport;
    viewport.setScreenScale(1);
    viewport.setPages({page});
    viewport.setScale(1);
    const pager::Rect atOne = viewport.tileDocumentFrame(pager::TileKey{0, 100, 0, 0});
    viewport.setScale(2);
    const pager::Rect atTwo = viewport.tileDocumentFrame(pager::TileKey{0, 200, 0, 0});
    const pager::Rect pageFrame = viewport.layout().pageFrame(0);
    XCTAssertEqualWithAccuracy(atOne.x, pageFrame.x, 0.001);
    XCTAssertEqualWithAccuracy(atOne.y, pageFrame.y, 0.001);
    XCTAssertGreaterThan(atOne.width, atTwo.width);
    XCTAssertGreaterThan(atOne.height, atTwo.height);
    XCTAssertEqualWithAccuracy(atTwo.x, pageFrame.x, 0.001);
    XCTAssertEqualWithAccuracy(atTwo.y, pageFrame.y, 0.001);
}

- (void)testCommitZoomKeepsAnchor {
    const pager::ZoomCommit commit = pager::CommitZoom(1, pager::Size{1000, 2000}, pager::Point{100, 50}, pager::Size{200, 100},
                                                       pager::Point{10, 10}, 2);
    XCTAssertEqual(commit.scale, 2);
    XCTAssertEqualWithAccuracy(commit.offset.x, 210, 0.001);
    XCTAssertEqualWithAccuracy(commit.offset.y, 110, 0.001);
}

- (void)testCommitPinchFollowsMovingCentroid {
    // Document point under (10, 10) at offset (100, 50) is (110, 60). After 2x it is (220, 120)
    // and should sit under the new centroid (40, 30): offset = (180, 90).
    const pager::ZoomCommit commit =
        pager::CommitPinch(1, pager::Size{1000, 2000}, pager::Point{100, 50}, pager::Size{200, 100},
                           pager::Point{10, 10}, pager::Point{40, 30}, 2);
    XCTAssertEqual(commit.scale, 2);
    XCTAssertEqualWithAccuracy(commit.offset.x, 180, 0.001);
    XCTAssertEqualWithAccuracy(commit.offset.y, 90, 0.001);
}

- (void)testCommitPinchZoomOutCentersInViewport {
    // A 100x200 document in a 400x400 view, pinched to 0.25, must rest on the
    // centering insets — not against the left/top edge.
    const pager::ZoomCommit commit =
        pager::CommitPinch(1, pager::Size{100, 200}, pager::Point{0, 0}, pager::Size{400, 400},
                           pager::Point{200, 200}, pager::Point{200, 200}, 0.25);
    XCTAssertEqualWithAccuracy(commit.scale, 0.25, 0.001);
    XCTAssertEqualWithAccuracy(commit.contentSize.width, 25, 0.001);
    XCTAssertEqualWithAccuracy(commit.contentSize.height, 50, 0.001);
    XCTAssertEqualWithAccuracy(commit.offset.x, -(400 - 25) * 0.5, 0.001);
    XCTAssertEqualWithAccuracy(commit.offset.y, -(400 - 50) * 0.5, 0.001);
}

- (void)testTileSlotsAreFullSquaresInsideAndStopAtThePageEdge {
    pager::PageGeometry page = Page(0, 0, 300, 300, pager::PageRotation::R0);
    page.index = 0;
    pager::Viewport viewport;
    viewport.setScreenScale(2);
    viewport.setScale(1);
    viewport.setPages({page});
    viewport.setVisibleRect(pager::Rect{0, 0, 2000, 2000});
    const std::vector<pager::TileSlot> slots = viewport.visibleSlots();
    XCTAssertEqual(slots.size(), 4u);
    const double tilePoints = 512.0 / (1.0 * 2.0);
    const pager::Rect pageFrame = viewport.layout().pageFrame(0);
    for (const pager::TileSlot &slot : slots) {
        const double expectedWidth = slot.key.column == 0 ? tilePoints : 300 - tilePoints;
        const double expectedHeight = slot.key.row == 0 ? tilePoints : 300 - tilePoints;
        XCTAssertEqualWithAccuracy(slot.documentFrame.width, expectedWidth, 0.5);
        XCTAssertEqualWithAccuracy(slot.documentFrame.height, expectedHeight, 0.5);
        XCTAssertLessThanOrEqual(slot.documentFrame.x + slot.documentFrame.width, pageFrame.x + pageFrame.width + 0.5);
        XCTAssertLessThanOrEqual(slot.documentFrame.y + slot.documentFrame.height, pageFrame.y + pageFrame.height + 0.5);
    }
}

- (void)testTileCacheEvictsLeastRecentlyUsed {
    auto tile = [](int page, int width) {
        pager::TileImage image;
        image.key = pager::TileKey{page, 0, 0, 0};
        image.width = width;
        image.height = 1;
        return image;
    };
    pager::TileCache cache(100);
    for (int index = 0; index < 3; ++index) {
        cache.insert(tile(index, 20));  // 80 bytes each
    }
    XCTAssertEqual(cache.count(), 1u);
    XCTAssertTrue(cache.find(pager::TileKey{2, 0, 0, 0}) != nullptr);
    XCTAssertTrue(cache.find(pager::TileKey{0, 0, 0, 0}) == nullptr);

    pager::TileCache lru(48);
    lru.insert(tile(0, 4));
    lru.insert(tile(1, 4));
    lru.insert(tile(2, 4));
    XCTAssertTrue(lru.touch(pager::TileKey{0, 0, 0, 0}) != nullptr);
    lru.insert(tile(3, 4));
    // Page 1 was the least recently used once page 0 was touched.
    XCTAssertTrue(lru.find(pager::TileKey{0, 0, 0, 0}) != nullptr);
    XCTAssertTrue(lru.find(pager::TileKey{1, 0, 0, 0}) == nullptr);
    XCTAssertEqual(lru.byteCount(), 48u);
}

- (void)testTilesRasterizeAtTheDensityTheyArePlacedAt {
    // At a pinch-end zoom like 1.2345 the tile key rounds to 1.23. Rendering at the raw zoom
    // but placing at the rounded one shifted column 4 by ~3pt and broke text at tile seams.
    struct RecordingSource : pager::PageRasterSource {
        std::mutex mutex;
        std::vector<double> scales;
        void drawPage(int, CGContextRef context, double, double) override {
            std::lock_guard<std::mutex> guard(mutex);
            scales.push_back(CGContextGetCTM(context).a);
        }
    };
    RecordingSource source;
    WaitClient client;
    client.band = pager::ScaleKeyForZoom(1.2345);
    pager::Viewport viewport;
    pager::PageGeometry page = Page(0, 0, 612, 792, pager::PageRotation::R0);
    page.index = 0;
    viewport.setPages({page});
    viewport.setScreenScale(2);
    viewport.setScale(1.2345);
    viewport.setClient(&client);
    viewport.setVisibleRect(pager::Rect{0, 0, 300, 300});
    viewport.requestVisibleTiles(source);
    std::unique_lock<std::mutex> lock(client.mutex);
    XCTAssertTrue(client.condition.wait_for(lock, std::chrono::seconds(5), [&] { return client.arrived; }));
    lock.unlock();
    viewport.stop();
    const pager::Rect frame = viewport.tileDocumentFrame(pager::TileKey{0, client.band, 0, 0});
    const double placedDensity = pager::Viewport::kTilePixels / frame.width;
    const double baseDensity = pager::ZoomForScaleKey(pager::Viewport::kBaseBand) * 2;
    std::lock_guard<std::mutex> guard(source.mutex);
    bool sawSharp = false;
    for (const double scale : source.scales) {
        const bool sharp = std::fabs(scale - placedDensity) < 1e-6;
        XCTAssertTrue(sharp || std::fabs(scale - baseDensity) < 1e-6, @"rendered at %f", scale);
        sawSharp = sawSharp || sharp;
    }
    XCTAssertTrue(sawSharp);
}

- (void)testPrefetchStaysWithinTheCacheAtHighZoom {
    std::vector<pager::PageGeometry> pages;
    for (int index = 0; index < 5; ++index) {
        pager::PageGeometry page = Page(0, 0, 612, 792, pager::PageRotation::R0);
        page.index = index;
        pages.push_back(page);
    }
    const std::size_t capacityTiles = (160ull * 1024 * 1024) / (512 * 512 * 4);
    for (double zoom : {1.0, 2.0, 4.0, 8.0}) {
        pager::Viewport viewport;
        viewport.setPages(pages);
        viewport.setScreenScale(2);
        viewport.setScale(zoom);
        viewport.setVisibleRect(pager::Rect{100, 900, 1024 / zoom, 1366 / zoom});
        XCTAssertLessThan(viewport.visibleSlots().size(), capacityTiles * 3 / 4, @"zoom %.0f", zoom);
        viewport.stop();
    }
}

- (void)testSimplifyCollinearStroke {
    std::vector<pager::InkSample> samples(4);
    samples[0].x = 0;
    samples[1].x = 1;
    samples[1].y = 0.01;
    samples[2].x = 2;
    samples[2].y = -0.01;
    samples[3].x = 10;
    const std::vector<pager::InkSample> simplified = pager::SimplifyStroke(samples, 0.5);
    XCTAssertEqual(simplified.size(), 2u);
}

- (void)testSmoothStrokeReducesJitterAndKeepsEndpoints {
    std::vector<pager::InkSample> samples;
    for (int index = 0; index <= 10; ++index) {
        pager::InkSample sample;
        sample.x = index;
        sample.y = index % 2 == 0 ? 0 : 2;  // heavy zig-zag jitter
        samples.push_back(sample);
    }
    const std::vector<pager::InkSample> smoothed = pager::SmoothStroke(samples);
    XCTAssertEqual(smoothed.size(), samples.size());
    XCTAssertEqualWithAccuracy(smoothed.front().y, 0, 0.001);
    XCTAssertEqualWithAccuracy(smoothed.back().y, 0, 0.001);
    XCTAssertEqualWithAccuracy(smoothed[5].y, 1.0, 0.001);  // 2 * 0.5 + (0 + 0) * 0.25
}

- (void)testZeroForceSampleKeepsMediumWidth {
    pager::InkSample sample;
    sample.force = 0;  // finger or not-yet-estimated Pencil sample
    XCTAssertEqualWithAccuracy(pager::InkWidthForSample(sample, 2, true), 2 * (0.46 + 0.68 * 0.55), 0.001);
    sample.force = 1;
    XCTAssertEqualWithAccuracy(pager::InkWidthForSample(sample, 2, true), 2 * (0.46 + 0.68), 0.001);
    XCTAssertEqualWithAccuracy(pager::InkWidthForSample(sample, 2, false), 2, 0.001);
    sample.altitude = 0.4f;  // flattened Pencil writes a slightly wider mark
    XCTAssertGreaterThan(pager::InkWidthForSample(sample, 2, true), 2 * (0.46 + 0.68));
    sample.altitude = 0;
    // Ordinary handwriting speed keeps full width; only fast flicks thin slightly.
    sample.speed = 120;
    XCTAssertEqualWithAccuracy(pager::InkWidthForSample(sample, 2, true), 2 * (0.46 + 0.68), 0.001);
    sample.speed = 900;
    XCTAssertLessThan(pager::InkWidthForSample(sample, 2, true), 2 * (0.46 + 0.68));
    XCTAssertGreaterThan(pager::InkWidthForSample(sample, 2, true), 2 * (0.46 + 0.68) * 0.79);
}

- (void)testResampleStrokeKeepsEndsAndFillsGaps {
    std::vector<pager::InkSample> samples(3);
    samples[0].x = 0;
    samples[1].x = 10;
    samples[1].y = 4;
    samples[2].x = 20;
    const std::vector<pager::InkSample> curve = pager::ResampleStroke(samples, 2);
    XCTAssertGreaterThan(curve.size(), samples.size());
    XCTAssertEqualWithAccuracy(curve.front().x, 0, 0.001);
    XCTAssertEqualWithAccuracy(curve.back().x, 20, 0.001);
}

- (void)testRibbonUsesAveragedJointsInsteadOfBareSegments {
    pager::PageGeometry page = Page(0, 0, 200, 200, pager::PageRotation::R0);
    std::vector<pager::InkSample> samples(4);
    samples[0].x = 10;
    samples[0].y = 10;
    samples[1].x = 40;
    samples[1].y = 14;
    samples[2].x = 70;
    samples[2].y = 8;
    samples[3].x = 100;
    samples[3].y = 12;
    const std::vector<pager::Triangle> ribbon = pager::BuildRibbon(samples, page, 2.2f, true);
    // Each pair of consecutive vertices is two triangles, plus two disc caps.
    XCTAssertGreaterThan(ribbon.size(), 8u);
}

- (void)testCommitPenKeepsADotForATap {
    pager::PageGeometry page = Page(0, 0, 100, 100, pager::PageRotation::R0);
    pager::DocumentSession session;
    session.viewport().setPages({page});
    session.setPenPage(0);
    pager::InkSample tap;
    tap.x = 20;
    tap.y = 24;
    session.pen().begin(tap);
    const pager::AnnotationId id = session.commitPen(0, page, pager::Color{0, 0, 0, 1}, 2.2f, true);
    XCTAssertTrue(id.value != 0);
    XCTAssertEqual(session.notes().annotations().back().samples.size(), 2u);
}

- (void)testCommitPenClampsStrokeToCropBox {
    pager::PageGeometry page = Page(10, 20, 100, 80, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    session.setPenPage(0);
    pager::InkSample inside;
    inside.x = 50;
    inside.y = 50;
    pager::InkSample outside;
    outside.x = 500;
    outside.y = -100;
    session.pen().begin(inside);
    session.pen().addCoalesced({outside});
    const pager::AnnotationId id = session.commitPen(0, page, pager::Color{0, 0, 0, 1}, 2, true);
    XCTAssertTrue(id.value != 0);
    const pager::Annotation &note = session.notes().annotations().back();
    for (const pager::InkSample &sample : note.samples) {
        XCTAssertGreaterThanOrEqual(sample.x, 10);
        XCTAssertLessThanOrEqual(sample.x, 110);
        XCTAssertGreaterThanOrEqual(sample.y, 20);
        XCTAssertLessThanOrEqual(sample.y, 100);
    }
    XCTAssertEqualWithAccuracy(note.opacity, 1, 0.001);
}

- (void)testToolStylesAndNoteUpdates {
    pager::PageGeometry page = Page(0, 0, 200, 200, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    session.setTool(pager::Tool::Pen);
    pager::ToolStyle pen = session.activeStyle();
    XCTAssertEqualWithAccuracy(pen.lineWidth, 2.2, 0.01);
    pen.color = pager::Color{1, 0, 0, 1};
    pen.lineWidth = 3.6f;
    session.setToolStyle(pager::Tool::Pen, pen);
    XCTAssertEqualWithAccuracy(session.toolStyle(pager::Tool::Pen).lineWidth, 3.6, 0.01);
    const pager::AnnotationId id = session.addTextNote(0, page, pager::Point{20, 40}, "Hello", pager::Color{0, 0, 1, 1}, 18);
    XCTAssertTrue(id.value != 0);
    const pager::Annotation *note = session.notes().find(id);
    XCTAssertTrue(note != nullptr);
    XCTAssertEqual(note->contents, "Hello");
    XCTAssertEqualWithAccuracy(note->fontSize, 18, 0.01);
    XCTAssertEqualWithAccuracy(note->color.b, 1, 0.01);
    const pager::AnnotationId blank = session.addTextNote(0, page, pager::Point{20, 80}, "", pager::Color{0, 0, 0, 1}, 14);
    const pager::Annotation *blankNote = session.notes().find(blank);
    XCTAssertTrue(blankNote != nullptr);
    XCTAssertTrue(blankNote->contents.empty());
    session.setSelectedNote(id);
    session.notes().beginEdit(id);
    pager::Annotation *editable = session.selectedAnnotationMutable();
    XCTAssertTrue(editable != nullptr);
    editable->fontSize = 24;
    editable->color = pager::Color{1, 0, 0, 1};
    XCTAssertTrue(session.notes().endEdit(id));
    XCTAssertEqualWithAccuracy(session.selectedAnnotation()->fontSize, 24, 0.01);
    session.notes().undo();
    XCTAssertEqualWithAccuracy(session.notes().find(id)->fontSize, 18, 0.01);
    session.notes().redo();
    XCTAssertEqualWithAccuracy(session.notes().find(id)->fontSize, 24, 0.01);
    XCTAssertFalse(session.notes().update(id, [](pager::Annotation &) {}));
}

- (void)testSanitizeSelectionDropsStaleSelection {
    pager::PageGeometry page = Page(0, 0, 100, 100, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    const pager::AnnotationId id = session.addShape(pager::AnnotationKind::Square, 0, page, pager::Point{10, 10},
                                                    pager::Point{40, 40}, {}, 1.5f);
    session.setSelectedNote(id);
    session.sanitizeSelection();
    XCTAssertTrue(session.selectedNote() == id);
    session.notes().remove(id);
    session.sanitizeSelection();
    XCTAssertTrue(session.selectedNote().value == 0);
}

- (void)testArchiveReadsLegacyStringGeometry {
    NSDictionary *entry = @{
        @"type" : @"Square",
        @"pageIndex" : @1,
        @"bounds" : @"{{10.5, 20.25}, {30.0, 40.0}}",
        @"startPoint" : @"{1.5, 2.5}",
        @"endPoint" : @"{3.5, 4.5}",
        @"color" : @[@1, @0, @0, @1],
        @"contents" : @"legacy",
        @"id" : @7,
        @"lineWidth" : @2,
        @"stableKey" : @"1",
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version" : @1, @"notes" : @[ entry ]}
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    pager::NoteDocument notes;
    NSError *error = nil;
    XCTAssertTrue([PagerNoteArchive readDocument:notes fromPlist:data error:&error], @"%@", error);
    XCTAssertEqual(notes.annotations().size(), 1u);
    const pager::Annotation &note = notes.annotations()[0];
    XCTAssertEqualWithAccuracy(note.bounds.x, 10.5, 0.001);
    XCTAssertEqualWithAccuracy(note.bounds.width, 30.0, 0.001);
    XCTAssertEqualWithAccuracy(note.lineStart.x, 1.5, 0.001);
    XCTAssertEqualWithAccuracy(note.lineEnd.y, 4.5, 0.001);
}

- (void)testArchiveRoundTripsFullPrecisionGeometry {
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *pdf = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"pager-%@.pdf", NSUUID.UUID.UUIDString]];
    [[@"%PDF" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:pdf atomically:YES];
    pager::NoteDocument notes;
    pager::Annotation note;
    note.kind = pager::AnnotationKind::Square;
    note.pageIndex = 0;
    note.bounds = pager::Rect{1.23456789, 2.34567891, 3.45678912, 4.56789123};
    notes.add(note);
    NSError *error = nil;
    XCTAssertTrue([PagerNoteArchive saveDocument:notes pdfURL:pdf error:&error], @"%@", error);
    pager::NoteDocument loaded;
    XCTAssertTrue([PagerNoteArchive loadDocument:loaded pdfURL:pdf error:&error], @"%@", error);
    XCTAssertEqual(loaded.annotations().size(), 1u);
    XCTAssertEqualWithAccuracy(loaded.annotations()[0].bounds.x, 1.23456789, 0.0000001);
    XCTAssertEqualWithAccuracy(loaded.annotations()[0].bounds.height, 4.56789123, 0.0000001);
}

- (void)testEraserSplitsStroke {
    pager::PageGeometry page = Page(0, 0, 100, 100, pager::PageRotation::R0);
    pager::Annotation ink;
    ink.kind = pager::AnnotationKind::Ink;
    ink.pageIndex = 0;
    for (int x = 0; x <= 40; x += 10) {
        pager::InkSample sample;
        sample.x = x;
        sample.y = 50;
        ink.samples.push_back(sample);
    }
    pager::NoteDocument notes;
    notes.add(ink);
    const pager::Point hit = pager::UserToPageView(page, pager::Point{20, 50});
    notes.eraseNear(0, page, hit, 3);
    XCTAssertEqual(notes.annotations().size(), 2u);
    XCTAssertLessThan(notes.annotations()[0].samples.back().x, 20);
    XCTAssertGreaterThan(notes.annotations()[1].samples.front().x, 20);
}

- (void)testNotesBindByPageIndexAcrossBothStores {
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *pdf = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"pager-%@.pdf", NSUUID.UUID.UUIDString]];
    [[@"%PDF" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:pdf atomically:YES];
    pager::NoteDocument notes;
    pager::Annotation note;
    note.kind = pager::AnnotationKind::Ink;
    note.pageIndex = 2;
    note.stableKey = "2";
    note.pressure = true;
    note.bounds = pager::Rect{1, 2, 3, 4};
    pager::InkSample sample;
    sample.x = 9;
    sample.y = 8;
    sample.force = 0.25f;
    note.samples.push_back(sample);
    note.samples.push_back(sample);
    notes.add(note);
    NSError *error = nil;
    XCTAssertTrue([PagerNoteArchive saveDocument:notes pdfURL:pdf error:&error], @"%@", error);
    [[NSFileManager defaultManager] removeItemAtURL:[PagerNoteArchive sidecarURLForPDF:pdf] error:nil];
    pager::NoteDocument loaded;
    XCTAssertTrue([PagerNoteArchive loadDocument:loaded pdfURL:pdf error:&error], @"%@", error);
    XCTAssertEqual(loaded.annotations().size(), 1u);
    XCTAssertEqual(loaded.annotations()[0].pageIndex, 2);
    XCTAssertEqual(loaded.annotations()[0].stableKey, "2");
    XCTAssertEqualWithAccuracy(loaded.annotations()[0].samples[0].force, 0.25, 0.001);
    NSData *plist = [NSData dataWithContentsOfURL:[PagerNoteArchive applicationSupportURLForPDF:pdf]];
    pager::NoteDocument fromBytes;
    XCTAssertTrue([PagerNoteArchive readDocument:fromBytes fromPlist:plist error:&error]);
    XCTAssertEqual(fromBytes.annotations()[0].pageIndex, loaded.annotations()[0].pageIndex);
}

- (void)testRenderedTileKeepsBottomBandDark {
    BlockSource source;
    WaitClient client;
    client.band = 100;
    pager::Viewport viewport;
    viewport.setClient(&client);
    viewport.setScreenScale(1);
    viewport.setScale(1);
    pager::PageGeometry page = Page(0, 0, 200, 200, pager::PageRotation::R0);
    page.index = 0;
    viewport.setPages({page});
    viewport.setVisibleRect(pager::Rect{0, 0, 2000, 2000});
    viewport.requestVisibleTiles(source);
    std::unique_lock<std::mutex> lock(client.mutex);
    XCTAssertTrue(client.condition.wait_for(lock, std::chrono::seconds(5), [&] { return client.arrived; }));
    XCTAssertEqual(client.image.width, 200);
    XCTAssertEqual(client.image.height, 200);
    const std::vector<std::uint8_t> pixels = Pixels(client.image.image.get());
    const int x = 100;
    const int top = 10;
    const int bottom = 180;
    XCTAssertTrue(IsWhite(pixels.data() + (top * 200 + x) * 4));
    XCTAssertTrue(IsBlack(pixels.data() + (bottom * 200 + x) * 4));
    lock.unlock();
    viewport.stop();
}

- (void)testPDFKitTextOutlineLinkFlattenAndImport {
    NSData *data = PDFWithHello(0);
    PDFKitPageSource *source = [[PDFKitPageSource alloc] init];
    NSError *error = nil;
    XCTAssertTrue([source openData:data error:&error], @"%@", error);
    pager::PageGeometry geometry = [source geometryAtIndex:0];
    XCTAssertEqualWithAccuracy(geometry.cropBox.width, 320, 0.1);
    XCTAssertEqual(geometry.stableKey, "0");
    std::vector<pager::TextSelection> hits = [source findString:@"Hello"];
    XCTAssertFalse(hits.empty());
    XCTAssertTrue(hits[0].text.find("Hello") != std::string::npos);
    pager::DocumentSession session;
    session.setSearchHits(hits);
    XCTAssertFalse(session.searchHits().empty());
    session.clearSearch();
    XCTAssertTrue(session.searchHits().empty());
    XCTAssertTrue(session.currentSearchHit() == nullptr);
    pager::TextSelection word = [source selectionForWordOnPage:0 atUser:pager::Point{60, 80}];
    XCTAssertFalse(word.quads.empty());
    pager::TextSelection miss = [source selectionForWordOnPage:0 atUser:pager::Point{NAN, 80}];
    XCTAssertTrue(miss.quads.empty());
    pager::TextSelection drag = [source selectionOnPage:0 fromUser:pager::Point{48, 72} toUser:pager::Point{120, 90}];
    XCTAssertFalse(drag.quads.empty());

    PDFDocument *document = [[PDFDocument alloc] initWithData:data];
    PDFPage *page = [document pageAtIndex:0];
    PDFAnnotation *highlight = [[PDFAnnotation alloc] initWithBounds:CGRectMake(40, 70, 80, 30)
                                                             forType:PDFAnnotationSubtypeHighlight
                                                      withProperties:nil];
    highlight.color = [NSColor colorWithRed:1 green:1 blue:0 alpha:1];
    [page addAnnotation:highlight];
    PDFAnnotation *link = [[PDFAnnotation alloc] initWithBounds:CGRectMake(40, 60, 40, 20)
                                                        forType:PDFAnnotationSubtypeLink
                                                 withProperties:nil];
    link.URL = [NSURL URLWithString:@"https://example.com"];
    [page addAnnotation:link];
    NSURL *savedURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"pager-annotated.pdf"]];
    XCTAssertTrue([document writeToURL:savedURL withOptions:nil]);
    PDFDocument *check = [[PDFDocument alloc] initWithURL:savedURL];
    PDFPage *checkPage = [check pageAtIndex:0];
    XCTAssertGreaterThan(checkPage.annotations.count, 1u);
    PDFKitPageSource *reopened = [[PDFKitPageSource alloc] init];
    XCTAssertTrue([reopened openURL:savedURL password:nil error:&error], @"%@", error);
    std::vector<pager::Annotation> imported = [reopened importAnnotations];
    XCTAssertEqual(imported.size(), 1u);
    XCTAssertEqual(imported[0].kind, pager::AnnotationKind::Highlight);
    pager::LinkHit hit = [reopened linkOnPage:0 atUser:pager::Point{50, 70}];
    XCTAssertTrue(hit.found);
    XCTAssertEqual(hit.url, "https://example.com");

    PDFKitPageSource *outlined = [[PDFKitPageSource alloc] init];
    XCTAssertTrue([outlined openData:PDFWithOutline() error:&error], @"%@", error);
    std::vector<pager::OutlineItem> outline = [outlined outlineItems];
    XCTAssertEqual(outline.size(), 1u);
    XCTAssertEqual(outline[0].title, "Start");
    XCTAssertEqual(outline[0].pageIndex, 0);

    NSData *rotated = PDFWithHello(90);
    PDFKitPageSource *rotatedSource = [[PDFKitPageSource alloc] init];
    XCTAssertTrue([rotatedSource openData:rotated error:&error], @"%@", error);
    pager::PageGeometry rotatedGeometry = [rotatedSource geometryAtIndex:0];
    XCTAssertEqual(rotatedGeometry.rotation, pager::PageRotation::R90);
    const pager::Size displayed = pager::DisplayedSize(rotatedGeometry);
    XCTAssertEqualWithAccuracy(displayed.width, rotatedGeometry.cropBox.height, 0.1);
    XCTAssertEqualWithAccuracy(displayed.height, rotatedGeometry.cropBox.width, 0.1);

    pager::DocumentSession flatSession;
    pager::Annotation square;
    square.kind = pager::AnnotationKind::Square;
    square.pageIndex = 0;
    square.bounds = pager::Rect{20, 20, 40, 30};
    square.color = pager::Color{1, 0, 0, 1};
    flatSession.addAnnotation(square);
    NSURL *flat = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"pager-flat.pdf"]];
    XCTAssertTrue([source writeFlattenedSession:flatSession toURL:flat error:&error], @"%@", error);
    PDFDocument *flattened = [[PDFDocument alloc] initWithURL:flat];
    XCTAssertEqual(flattened.pageCount, 1u);
}

- (void)testRotatedPageRendersWithoutDistortion {
    // 320x180 page rotated 90 degrees displays as 180x320. The "Hello" baseline sits at user
    // (48, 72), which maps to displayed (72, 48). A scale computed from the unrotated box
    // would squash x by 180/320 and stretch y by 320/180, moving the text to ~(40, 85).
    NSData *data = PDFWithHello(90);
    PDFKitPageSource *source = [[PDFKitPageSource alloc] init];
    NSError *error = nil;
    XCTAssertTrue([source openData:data error:&error], @"%@", error);
    const pager::PageGeometry geometry = [source geometryAtIndex:0];
    const pager::Size displayed = pager::DisplayedSize(geometry);
    const int width = static_cast<int>(displayed.width);
    const int height = static_cast<int>(displayed.height);
    std::vector<std::uint8_t> bgra(static_cast<std::size_t>(width * height * 4), 255);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bgra.data(), static_cast<size_t>(width), static_cast<size_t>(height), 8,
                                                 static_cast<size_t>(width * 4), colorSpace,
                                                 static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) |
                                                     static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little));
    CGColorSpaceRelease(colorSpace);
    XCTAssertTrue(context != nullptr);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    // Mirror Viewport::render's CTM so the source draws into a y-down pixel buffer.
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1, -1);
    [source rasterSource]->drawPage(0, context, displayed.width, displayed.height);
    CGContextRelease(context);
    auto darkPixels = [&](int minX, int minY, int maxX, int maxY) {
        int count = 0;
        for (int y = minY; y < maxY; ++y) {
            for (int x = minX; x < maxX; ++x) {
                const std::uint8_t *pixel = bgra.data() + (y * width + x) * 4;
                if (pixel[0] < 128 && pixel[1] < 128 && pixel[2] < 128) {
                    ++count;
                }
            }
        }
        return count;
    };
    XCTAssertGreaterThan(darkPixels(70, 45, 140, 75), 10);   // where the text should be
    XCTAssertEqual(darkPixels(35, 85, 60, 130), 0);          // where distortion would put it
}

- (void)testMacCanvasShowsPageAndAnnotationTilesAndDraws {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"pager-view-test.pdf"]];
    XCTAssertTrue([PDFWithHello(0) writeToURL:url atomically:YES]);
    PagerDocument *document = [[PagerDocument alloc] init];
    NSError *error = nil;
    XCTAssertTrue([document readFromURL:url ofType:@"pdf" error:&error], @"%@", error);
    document.session.notes().replaceAll({});

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 500)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:window.contentView.bounds];
    PagerCanvasView *canvas = [[PagerCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    scroll.documentView = canvas;
    window.contentView = scroll;
    [canvas attachToDocument:document];
    XCTAssertTrue(canvas.isFlipped);
    const pager::Size content = document.session.viewport().layout().contentSize();
    XCTAssertEqualWithAccuracy(canvas.frame.size.width, content.width, 0.5);
    XCTAssertEqualWithAccuracy(canvas.frame.size.height, content.height, 0.5);

    // Page rasters arrive as tile layers; no document-sized bitmap is ever drawn.
    XCTAssertTrue(SpinUntil(5, ^BOOL { return canvas.controller.tileLayerCount > 0; }));

    pager::Annotation ink = StraightInk(40, 200, 100, 8);
    document.session.addAnnotation(ink);
    [canvas.controller contentDidChange];
    XCTAssertTrue(SpinUntil(5, ^BOOL { return canvas.controller.annotationLayerCount > 0; }));

    // A pen gesture through the shared controller commits one more note.
    document.session.setTool(pager::Tool::Pen);
    const pager::Rect frame = document.session.viewport().layout().pageFrame(0);
    const pager::Point start{frame.x + 40, frame.y + 40};
    XCTAssertEqual([canvas.controller beginGestureAt:start clickCount:1], PagerGestureInk);
    std::vector<pager::InkSample> first{[canvas.controller inkSampleAt:start force:0 altitude:0 azimuth:0 time:1 predicted:NO]};
    [canvas.controller beginInk:first predicted:std::vector<pager::InkSample>{}];
    XCTAssertTrue([canvas.controller liveHasContent]);
    for (int step = 1; step <= 10; ++step) {
        const pager::Point point{start.x + step * 8, start.y + step * 2};
        std::vector<pager::InkSample> more{[canvas.controller inkSampleAt:point force:0 altitude:0 azimuth:0 time:1 + step * 0.01 predicted:NO]};
        [canvas.controller appendInk:more predicted:std::vector<pager::InkSample>{}];
    }
    [canvas.controller endGestureAt:pager::Point{start.x + 80, start.y + 20}];
    XCTAssertEqual(document.session.notes().annotations().size(), 2u);
    XCTAssertEqual(document.session.notes().annotations().back().kind, pager::AnnotationKind::Ink);

    // With the Select tool, a drag over a note moves it (Preview behaviour) as one undo step.
    document.session.setTool(pager::Tool::Scroll);
    const pager::Annotation drawn = document.session.notes().annotations().back();
    const CGRect drawnRect = [canvas.controller documentRectForNote:drawn];
    const pager::Point grab{CGRectGetMidX(drawnRect), CGRectGetMidY(drawnRect)};
    XCTAssertEqual([canvas.controller beginGestureAt:grab clickCount:1], PagerGestureHandle);
    [canvas.controller moveGestureTo:pager::Point{grab.x + 30, grab.y}];
    [canvas.controller endGestureAt:pager::Point{grab.x + 30, grab.y}];
    XCTAssertGreaterThan(document.session.notes().annotations().back().samples.front().x, drawn.samples.front().x + 29);
    document.session.notes().undo();
    XCTAssertEqualWithAccuracy(document.session.notes().annotations().back().samples.front().x, drawn.samples.front().x, 1e-9);

    [canvas detach];
    [document close];
}

- (void)testLiveShapeCanBeSelectedAndRemoved {
    pager::PageGeometry page = Page(0, 0, 300, 200, pager::PageRotation::R0);
    pager::DocumentSession session;
    session.viewport().setPages({page});
    session.viewport().setScale(1);
    session.setShapeDraft(pager::AnnotationKind::Line, 0, pager::Point{20, 40}, pager::Point{180, 40});
    XCTAssertTrue(session.shapeDraft().active);
    session.addShape(pager::AnnotationKind::Line, 0, page, pager::Point{20, 40}, pager::Point{180, 40}, {}, 2);
    session.clearShapeDraft();
    XCTAssertFalse(session.shapeDraft().active);
    const pager::Point onLine = session.viewport().layout().pageViewToDocument(0, pager::Point{90, 40});
    XCTAssertTrue(session.selectNoteAt(onLine));
    XCTAssertTrue(session.deleteSelectedNote());
    XCTAssertEqual(session.notes().annotations().size(), 0u);

    session.addShape(pager::AnnotationKind::Circle, 0, page, pager::Point{30, 30}, pager::Point{90, 90}, {}, 2);
    const pager::Point inside = session.viewport().layout().pageViewToDocument(0, pager::Point{60, 60});
    XCTAssertTrue(session.selectNoteAt(inside));
    session.eraseAt(0, page, pager::Point{60, 60}, 8);
    XCTAssertEqual(session.notes().annotations().size(), 0u);

    const pager::AnnotationId textId = session.addTextNote(0, page, pager::Point{80, 80}, "hello", {}, 14);
    XCTAssertTrue(textId.value != 0);
    XCTAssertEqual(session.notes().annotations().size(), 1u);
    // The box's top-left corner is the tap point (80, 80); the eraser reaches it from above.
    session.eraseAt(0, page, pager::Point{80, 75}, 8);
    XCTAssertEqual(session.notes().annotations().size(), 0u);
    XCTAssertTrue(session.notes().find(textId) == nullptr);
}

- (void)testEraserCutsAStraightStrokeBetweenItsSamples {
    // A ruler-straight stroke is stored as just its two end samples; the eraser used to test
    // samples only and could never touch its middle.
    pager::PageGeometry page = Page(0, 0, 400, 400, pager::PageRotation::R0);
    pager::NoteDocument notes;
    notes.add(StraightInk(100, 300, 200, 2));
    const pager::Point middle = pager::UserToPageView(page, pager::Point{200, 200});
    notes.eraseNear(0, page, middle, 6);
    XCTAssertEqual(notes.annotations().size(), 2u);
    const pager::Annotation &left = notes.annotations()[0];
    const pager::Annotation &right = notes.annotations()[1];
    XCTAssertLessThan(left.samples.back().x, 200 - 6);
    XCTAssertGreaterThan(left.samples.back().x, 200 - 10);
    XCTAssertGreaterThan(right.samples.front().x, 200 + 6);
    XCTAssertTrue(left.cutEnd);
    XCTAssertFalse(left.cutStart);
    XCTAssertTrue(right.cutStart);
    XCTAssertFalse(right.cutEnd);
}

- (void)testEraserSweepCatchesStrokesBetweenTouchEvents {
    pager::PageGeometry page = Page(0, 0, 400, 400, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    pager::Annotation vertical;
    vertical.kind = pager::AnnotationKind::Ink;
    vertical.pageIndex = 0;
    vertical.lineWidth = 2;
    for (int y = 120; y <= 280; y += 40) {
        pager::InkSample sample;
        sample.x = 200;
        sample.y = y;
        vertical.samples.push_back(sample);
    }
    vertical.bounds = pager::Rect{200, 120, 1, 160};
    session.addAnnotation(vertical);
    // Two eraser events 100pt apart, one on each side of the stroke: neither touches it, the
    // swipe between them does.
    const pager::Point from = pager::UserToPageView(page, pager::Point{150, 200});
    const pager::Point to = pager::UserToPageView(page, pager::Point{250, 200});
    XCTAssertFalse(pager::HitsAnnotation(vertical, page, from, 5));
    XCTAssertFalse(pager::HitsAnnotation(vertical, page, to, 5));
    XCTAssertTrue(session.eraseAlong(0, page, from, to, 5));
    XCTAssertEqual(session.notes().annotations().size(), 2u);
}

- (void)testInkHitTestUsesSegments {
    pager::PageGeometry page = Page(0, 0, 400, 400, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    session.addAnnotation(StraightInk(100, 300, 200, 2));
    const pager::Point onStroke = session.viewport().layout().pageViewToDocument(
        0, pager::Point{200, 400 - 200 + 2});
    XCTAssertTrue(session.selectNoteAt(onStroke));
    const pager::Point farAway = session.viewport().layout().pageViewToDocument(0, pager::Point{200, 400 - 200 + 30});
    XCTAssertFalse(session.selectNoteAt(farAway));
}

- (void)testEraserDragIsOneUndoStepAndUndoIsIncremental {
    pager::PageGeometry page = Page(0, 0, 400, 400, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    for (int line = 0; line < 5; ++line) {
        session.addAnnotation(StraightInk(50, 350, 50 + line * 40, 30));
    }
    const std::size_t strokes = session.notes().annotations().size();
    session.notes().beginGroup();
    for (int step = 0; step < 40; ++step) {
        const pager::Point a = pager::UserToPageView(page, pager::Point{200, 30 + step * 6.0});
        const pager::Point b = pager::UserToPageView(page, pager::Point{200, 36 + step * 6.0});
        session.eraseAlong(0, page, a, b, 4);
    }
    session.notes().endGroup();
    XCTAssertGreaterThan(session.notes().annotations().size(), strokes);
    session.notes().undo();
    XCTAssertEqual(session.notes().annotations().size(), strokes);
    for (const pager::Annotation &note : session.notes().annotations()) {
        XCTAssertEqual(note.samples.size(), 30u);
    }
    session.notes().redo();
    XCTAssertGreaterThan(session.notes().annotations().size(), strokes);
    session.notes().undo();
    for (std::size_t index = 0; index < strokes; ++index) {
        session.notes().undo();
    }
    XCTAssertEqual(session.notes().annotations().size(), 0u);
    XCTAssertFalse(session.notes().canUndo());
}

- (void)testTextEditMergesIntoCreationAndEmptyBoxLeavesNoHistory {
    pager::PageGeometry page = Page(0, 0, 400, 400, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    pager::NoteDocument &notes = session.notes();
    const pager::AnnotationId typed = session.addTextNote(0, page, pager::Point{20, 20}, "", {}, 14);
    notes.beginEdit(typed);
    notes.findMutable(typed)->contents = "Hello";
    XCTAssertTrue(notes.endEdit(typed, true));
    notes.undo();
    XCTAssertTrue(notes.find(typed) == nullptr);
    XCTAssertFalse(notes.canUndo());
    notes.redo();
    XCTAssertEqual(notes.find(typed)->contents, "Hello");

    const pager::AnnotationId empty = session.addTextNote(0, page, pager::Point{20, 100}, "", {}, 14);
    notes.beginEdit(empty);
    notes.discardAdd(empty);
    XCTAssertTrue(notes.find(empty) == nullptr);
    notes.undo();
    XCTAssertTrue(notes.find(typed) == nullptr);

    // Editing an existing note's text is undoable (the snapshot used to be taken after the edit).
    notes.redo();
    notes.beginEdit(typed);
    notes.findMutable(typed)->contents = "Changed";
    XCTAssertTrue(notes.endEdit(typed));
    notes.undo();
    XCTAssertEqual(notes.find(typed)->contents, "Hello");
}

- (void)testPageRevisionsTrackOnlyTouchedPages {
    pager::NoteDocument notes;
    pager::Annotation first = StraightInk(0, 10, 10, 2);
    pager::Annotation second = first;
    second.pageIndex = 3;
    notes.add(first);
    const std::uint64_t pageZero = notes.pageRevision(0);
    const std::uint64_t pageThree = notes.pageRevision(3);
    notes.add(second);
    XCTAssertEqual(notes.pageRevision(0), pageZero);
    XCTAssertGreaterThan(notes.pageRevision(3), pageThree);
    notes.undo();
    XCTAssertGreaterThan(notes.pageRevision(3), pageThree);
}

- (void)testCommittedStrokeIsTheStrokeThatWasDrawn {
    pager::PageGeometry page = Page(0, 0, 400, 400, pager::PageRotation::R0);
    page.index = 0;
    pager::DocumentSession session;
    session.viewport().setPages({page});
    pager::InkSample sample;
    sample.x = 50;
    sample.y = 200;
    sample.force = 0.4f;
    sample.time = 1;
    session.pen().begin(sample);
    std::vector<pager::InkSample> more;
    for (int index = 1; index <= 120; ++index) {
        pager::InkSample next = sample;
        next.x = 50 + index * 2.0;
        next.y = 200 + std::sin(index * 0.15) * 20;
        // Pressure ramps along a straight-ish run; simplification must keep it.
        next.force = 0.4f + 0.8f * index / 120.0f;
        next.time = 1 + index * 0.004;
        more.push_back(next);
    }
    session.pen().addCoalesced(more);
    const std::vector<pager::InkSample> live = session.pen().display();
    const std::vector<pager::Triangle> liveRibbon = pager::BuildRibbon(live, page, 2.2f, true);
    session.commitPen(0, page, pager::Color{0, 0, 0, 1}, 2.2f, true);
    const pager::Annotation &note = session.notes().annotations().back();
    const std::vector<pager::Triangle> committedRibbon = pager::BuildRibbon(note.samples, page, 2.2f, true);
    auto bounds = [](const std::vector<pager::Triangle> &triangles) {
        pager::Rect rect{triangles[0].a.x, triangles[0].a.y, 0, 0};
        for (const pager::Triangle &triangle : triangles) {
            for (const pager::Point &point : {triangle.a, triangle.b, triangle.c}) {
                rect = rect.united(pager::Rect{point.x, point.y, 0.0001, 0.0001});
            }
        }
        return rect;
    };
    const pager::Rect a = bounds(liveRibbon);
    const pager::Rect b = bounds(committedRibbon);
    XCTAssertEqualWithAccuracy(a.x, b.x, 0.1);
    XCTAssertEqualWithAccuracy(a.y, b.y, 0.1);
    XCTAssertEqualWithAccuracy(a.width, b.width, 0.1);
    XCTAssertEqualWithAccuracy(a.height, b.height, 0.1);
    XCTAssertGreaterThan(note.samples.back().force, 1.0f);
}

- (void)testRibbonTrianglesShareOneWinding {
    pager::PageGeometry page = Page(0, 0, 200, 200, pager::PageRotation::R0);
    std::vector<pager::InkSample> samples;
    for (int index = 0; index < 60; ++index) {
        pager::InkSample sample;
        sample.x = 100 + std::cos(index * 0.3) * (10 + index);
        sample.y = 100 + std::sin(index * 0.3) * (10 + index);
        sample.force = 0.3f + (index % 7) * 0.1f;
        samples.push_back(sample);
    }
    for (const pager::Triangle &triangle : pager::BuildRibbon(samples, page, 3, true)) {
        const double cross = (triangle.b.x - triangle.a.x) * (triangle.c.y - triangle.a.y) -
                             (triangle.b.y - triangle.a.y) * (triangle.c.x - triangle.a.x);
        XCTAssertGreaterThanOrEqual(cross, 0);
    }
}

- (void)testMarkupAcrossAPageBreakMakesOneNotePerPage {
    pager::PageGeometry first = Page(0, 0, 300, 300, pager::PageRotation::R0);
    first.index = 0;
    first.stableKey = "0";
    pager::PageGeometry second = first;
    second.index = 1;
    second.stableKey = "1";
    pager::DocumentSession session;
    session.viewport().setPages({first, second});
    pager::TextSelection selection;
    selection.text = "across";
    for (int pageIndex = 0; pageIndex < 2; ++pageIndex) {
        pager::SelectionQuad quad;
        quad.pageIndex = pageIndex;
        quad.quad.v[0] = pager::Point{10, 10};
        quad.quad.v[1] = pager::Point{60, 10};
        quad.quad.v[2] = pager::Point{60, 22};
        quad.quad.v[3] = pager::Point{10, 22};
        selection.quads.push_back(quad);
    }
    session.addMarkup(pager::AnnotationKind::Highlight, selection, pager::Color{1, 1, 0, 0.4f});
    XCTAssertEqual(session.notes().annotations().size(), 2u);
    XCTAssertEqual(session.notes().annotations()[0].pageIndex, 0);
    XCTAssertEqual(session.notes().annotations()[1].pageIndex, 1);
    XCTAssertEqual(session.notes().annotations()[1].stableKey, "1");
    session.notes().undo();
    XCTAssertEqual(session.notes().annotations().size(), 0u);
}

- (void)testArchiveRoundTripsPackedInkAndCutEnds {
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *pdf = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"pager-%@.pdf", NSUUID.UUID.UUIDString]];
    [[@"%PDF" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:pdf atomically:YES];
    pager::NoteDocument notes;
    pager::Annotation ink = StraightInk(1.25, 9.5, 3.75, 5);
    ink.samples[2].force = 0.33f;
    ink.samples[3].altitude = 0.9f;
    ink.cutStart = true;
    ink.pressure = true;
    notes.add(ink);
    NSError *error = nil;
    XCTAssertTrue([PagerNoteArchive saveDocument:notes pdfURL:pdf error:&error], @"%@", error);
    pager::NoteDocument loaded;
    XCTAssertTrue([PagerNoteArchive loadDocument:loaded pdfURL:pdf error:&error], @"%@", error);
    XCTAssertEqual(loaded.annotations().size(), 1u);
    const pager::Annotation &back = loaded.annotations()[0];
    XCTAssertEqual(back.samples.size(), 5u);
    XCTAssertEqual(back.samples[4].x, 9.5);
    XCTAssertEqualWithAccuracy(back.samples[2].force, 0.33, 1e-6);
    XCTAssertEqualWithAccuracy(back.samples[3].altitude, 0.9, 1e-6);
    XCTAssertTrue(back.cutStart);
    XCTAssertFalse(back.cutEnd);
    XCTAssertTrue(back.pressure);
}

- (void)testArchivePrefersTheNewerStore {
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *pdf = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"pager-%@.pdf", NSUUID.UUID.UUIDString]];
    [[@"%PDF" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:pdf atomically:YES];
    pager::NoteDocument stale;
    pager::Annotation note = StraightInk(0, 10, 10, 2);
    stale.add(note);
    [[PagerNoteArchive plistDataForDocument:stale bookmark:nil] writeToURL:[PagerNoteArchive sidecarURLForPDF:pdf] atomically:YES];
    [NSThread sleepForTimeInterval:0.01];
    pager::NoteDocument fresh;
    fresh.add(note);
    fresh.add(note);
    NSURL *store = [PagerNoteArchive applicationSupportURLForPDF:pdf];
    [NSFileManager.defaultManager createDirectoryAtURL:[store URLByDeletingLastPathComponent]
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    [[PagerNoteArchive plistDataForDocument:fresh bookmark:nil] writeToURL:store atomically:YES];
    pager::NoteDocument loaded;
    XCTAssertTrue([PagerNoteArchive loadDocument:loaded pdfURL:pdf error:nil]);
    XCTAssertEqual(loaded.annotations().size(), 2u);
}

- (void)testFlattenedExportMatchesTheScreen {
    NSData *data = PDFWithHello(0);
    PDFKitPageSource *source = [[PDFKitPageSource alloc] init];
    NSError *error = nil;
    XCTAssertTrue([source openData:data error:&error], @"%@", error);
    const pager::PageGeometry geometry = [source geometryAtIndex:0];
    std::vector<pager::Annotation> notes;
    // A box over blank paper: on screen it is a faint 15% tint, so the export must be too.
    pager::Annotation square;
    square.kind = pager::AnnotationKind::Square;
    square.pageIndex = 0;
    square.color = pager::Color{1, 0, 0, 1};
    square.lineWidth = 1;
    square.bounds = pager::Rect{200, 20, 100, 60};
    notes.push_back(square);
    // A text box at the top-left: its words must sit at the top of the box, upright.
    pager::Annotation text;
    text.kind = pager::AnnotationKind::FreeText;
    text.pageIndex = 0;
    text.color = pager::Color{0, 0, 0, 1};
    text.fontSize = 16;
    text.contents = "HHHH";
    text.bounds = pager::Rect{10, 100, 140, 70};  // user space: page-view y from 10 to 80
    notes.push_back(text);
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"pager-export-test.pdf"]];
    XCTAssertTrue([source writeFlattenedNotes:notes toURL:url error:&error], @"%@", error);

    CGPDFDocumentRef pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    XCTAssertTrue(pdf != nullptr);
    CGPDFPageRef page = CGPDFDocumentGetPage(pdf, 1);
    const pager::Size displayed = pager::DisplayedSize(geometry);
    const int width = static_cast<int>(displayed.width);
    const int height = static_cast<int>(displayed.height);
    std::vector<std::uint8_t> pixels(static_cast<std::size_t>(width * height * 4), 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.data(), width, height, 8, width * 4, space,
                                                 static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) |
                                                     static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little));
    CGColorSpaceRelease(space);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextDrawPDFPage(context, page);
    CGContextRelease(context);
    CGPDFDocumentRelease(pdf);
    // Bitmap rows are top-first here, matching page-view y.
    auto pixel = [&](int x, int y) { return pixels.data() + (y * width + x) * 4; };
    const std::uint8_t *inside = pixel(250, 180 - 50);
    XCTAssertGreaterThan(inside[1], 200);  // green channel barely reduced: a light tint, not opaque red
    const int topHalf = CountDark(pixels, width, 14, 12, 140, 44);
    const int bottomHalf = CountDark(pixels, width, 14, 46, 140, 76);
    XCTAssertGreaterThan(topHalf, 20);
    XCTAssertGreaterThan(topHalf, bottomHalf * 3);
}

- (void)testImportReadsAuthoredAnnotationGeometry {
    PDFKitPageSource *source = [[PDFKitPageSource alloc] init];
    NSError *error = nil;
    XCTAssertTrue([source openURL:PDFWithAuthoredAnnotations() password:nil error:&error], @"%@", error);
    const std::vector<pager::Annotation> imported = [source importAnnotations];
    const pager::Annotation *highlight = nullptr;
    const pager::Annotation *line = nullptr;
    std::vector<const pager::Annotation *> ink;
    for (const pager::Annotation &note : imported) {
        if (note.kind == pager::AnnotationKind::Highlight) {
            highlight = &note;
        } else if (note.kind == pager::AnnotationKind::Line) {
            line = &note;
        } else if (note.kind == pager::AnnotationKind::Ink) {
            ink.push_back(&note);
        }
    }
    XCTAssertTrue(highlight != nullptr);
    XCTAssertTrue(line != nullptr);
    XCTAssertEqual(highlight->quads.size(), 1u);
    // Bottom-left, bottom-right, top-right, top-left in page user space.
    XCTAssertEqualWithAccuracy(highlight->quads[0].v[0].x, 100, 0.01);
    XCTAssertEqualWithAccuracy(highlight->quads[0].v[0].y, 200, 0.01);
    XCTAssertEqualWithAccuracy(highlight->quads[0].v[1].x, 180, 0.01);
    XCTAssertEqualWithAccuracy(highlight->quads[0].v[2].y, 220, 0.01);
    XCTAssertEqualWithAccuracy(line->lineStart.x, 60, 0.01);
    XCTAssertEqualWithAccuracy(line->lineStart.y, 60, 0.01);
    XCTAssertEqualWithAccuracy(line->lineEnd.x, 140, 0.01);
    XCTAssertEqualWithAccuracy(line->lineEnd.y, 110, 0.01);
    XCTAssertEqual(ink.size(), 2u);
    XCTAssertEqual(ink[0]->samples.size(), 3u);
    XCTAssertEqualWithAccuracy(ink[0]->samples[0].x, 210, 0.01);
    XCTAssertEqualWithAccuracy(ink[0]->samples[2].y, 250, 0.01);
    XCTAssertEqual(ink[1]->samples.size(), 2u);
    XCTAssertEqualWithAccuracy(ink[1]->samples[1].x, 280, 0.01);
}

- (void)testAnnotationRasterizerPaintsOnlyTilesWithNotes {
    pager::PageGeometry page = Page(0, 0, 400, 400, pager::PageRotation::R0);
    page.index = 0;
    pager::Annotation ink = StraightInk(20, 120, 380, 12);
    ink.color = pager::Color{0, 0, 0, 1};
    ink.lineWidth = 6;
    pager::PageAnnotationsRef snapshot = pager::MakePageAnnotations(0, page, 7, {ink}, {});
    std::mutex mutex;
    std::condition_variable condition;
    std::vector<pager::AnnotationTile> tiles;
    pager::AnnotationRasterizer rasterizer;
    rasterizer.setCallback([&](pager::AnnotationTile tile) {
        std::lock_guard<std::mutex> guard(mutex);
        tiles.push_back(std::move(tile));
        condition.notify_all();
    });
    pager::AnnotationTileJob touched;
    touched.key = pager::TileKey{0, 100, 0, 0};
    touched.snapshot = snapshot;
    touched.pageRect = pager::Rect{0, 0, 200, 200};
    touched.pixelsPerPoint = 1;
    touched.pixelWidth = 200;
    touched.pixelHeight = 200;
    pager::AnnotationTileJob empty = touched;
    empty.key = pager::TileKey{0, 100, 0, 1};
    empty.pageRect = pager::Rect{0, 200, 200, 200};
    rasterizer.submit({touched, empty});
    std::unique_lock<std::mutex> lock(mutex);
    XCTAssertTrue(condition.wait_for(lock, std::chrono::seconds(5), [&] { return tiles.size() == 2; }));
    XCTAssertTrue(tiles[0].image);
    XCTAssertEqual(tiles[0].revision, 7u);
    XCTAssertFalse(tiles[1].image);
    const std::vector<std::uint8_t> pixels = Pixels(tiles[0].image.get());
    // User y 380 is page-view y 20; the stroke runs from x 20 to 120.
    XCTAssertGreaterThan(pixels[(20 * 200 + 70) * 4 + 3], 200);
    XCTAssertEqual(pixels[(120 * 200 + 70) * 4 + 3], 0);
    lock.unlock();
    rasterizer.stop();
}

- (void)testSwappingRasterSourcesWaitsForInFlightRenders {
    struct SlowSource : pager::PageRasterSource {
        std::atomic<int> active{0};
        std::atomic<int> started{0};
        void drawPage(int, CGContextRef, double, double) override {
            ++active;
            ++started;
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            --active;
        }
    };
    auto source = std::make_unique<SlowSource>();
    pager::Viewport viewport;
    pager::PageGeometry page = Page(0, 0, 2000, 2000, pager::PageRotation::R0);
    page.index = 0;
    viewport.setPages({page});
    viewport.setScreenScale(1);
    viewport.setVisibleRect(pager::Rect{0, 0, 1500, 1500});
    viewport.requestVisibleTiles(*source);
    while (source->started.load() == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    viewport.setSource(nullptr);
    XCTAssertEqual(source->active.load(), 0);
    source.reset();
    viewport.stop();
}

@end
