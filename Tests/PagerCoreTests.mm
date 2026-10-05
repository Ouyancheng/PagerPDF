#import <XCTest/XCTest.h>
#import <PDFKit/PDFKit.h>
#import <CoreText/CoreText.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#import "NoteArchive.h"
#import "PDFKitPageSource.h"
#import "PagerDocument.h"
#import "PagerDocumentView.h"

#include "DocumentSession.hpp"
#include "Geometry.hpp"
#include "Ink.hpp"
#include "Layout.hpp"
#include "NoteDocument.hpp"
#include "TileCache.hpp"
#include "Viewport.hpp"
#include "Zoom.hpp"

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <mutex>

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
    pager::TileImage image;

    void tileReady(pager::TileImage tile) override {
        std::lock_guard<std::mutex> guard(mutex);
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
    pager::PageGeometry page = Page(0, 0, 200, 200, pager::PageRotation::R0);
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

- (void)testTileSlotsKeepFullSquare {
    pager::PageGeometry page = Page(0, 0, 300, 300, pager::PageRotation::R0);
    page.index = 0;
    pager::Viewport viewport;
    viewport.setScreenScale(2);
    viewport.setScale(1);
    viewport.setPages({page});
    viewport.setVisibleRect(pager::Rect{0, 0, 2000, 2000});
    const std::vector<pager::TileSlot> slots = viewport.visibleSlots();
    XCTAssertGreaterThanOrEqual(slots.size(), 2u);
    const double tilePoints = 512.0 / (1.0 * 2.0);
    for (const pager::TileSlot &slot : slots) {
        XCTAssertEqualWithAccuracy(slot.documentFrame.width, tilePoints, 0.001);
        XCTAssertEqualWithAccuracy(slot.documentFrame.height, tilePoints, 0.001);
    }
}

- (void)testTileCacheEvictsOldest {
    pager::TileCache cache(100);
    for (int index = 0; index < 3; ++index) {
        pager::TileImage image;
        image.key = pager::TileKey{index, 0, 0, 0};
        image.bgra.assign(80, 1);
        cache.insert(std::move(image));
    }
    XCTAssertEqual(cache.count(), 1u);
    pager::TileImage latest;
    latest.key = pager::TileKey{2, 0, 0, 0};
    latest.bgra.assign(1, 1);
    cache.insert(std::move(latest));
    pager::TileImage probe;
    probe.key = pager::TileKey{0, 0, 0, 0};
    pager::TileCache lookup(100);
    (void)lookup;
    pager::TileImage kept;
    kept.key = pager::TileKey{2, 0, 0, 0};
    XCTAssertTrue(cache.find(kept.key) != nullptr);
    XCTAssertTrue(cache.find(probe.key) == nullptr);
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
    sample.speed = 80;
    XCTAssertLessThan(pager::InkWidthForSample(sample, 2, true), 2 * (0.46 + 0.68));
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
    session.notes().snapshot();
    pager::Annotation *editable = session.selectedAnnotationMutable();
    XCTAssertTrue(editable != nullptr);
    editable->fontSize = 24;
    editable->color = pager::Color{1, 0, 0, 1};
    XCTAssertEqualWithAccuracy(session.selectedAnnotation()->fontSize, 24, 0.01);
    session.notes().undo();
    XCTAssertEqualWithAccuracy(session.notes().find(id)->fontSize, 18, 0.01);
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
    const int x = 100;
    const int top = 10;
    const int bottom = 180;
    const std::uint8_t *topPixel = client.image.bgra.data() + top * client.image.bytesPerRow + x * 4;
    const std::uint8_t *bottomPixel = client.image.bgra.data() + bottom * client.image.bytesPerRow + x * 4;
    XCTAssertTrue(IsWhite(topPixel));
    XCTAssertTrue(IsBlack(bottomPixel));
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

    pager::DocumentSession session;
    pager::Annotation square;
    square.kind = pager::AnnotationKind::Square;
    square.pageIndex = 0;
    square.bounds = pager::Rect{20, 20, 40, 30};
    square.color = pager::Color{1, 0, 0, 1};
    session.addAnnotation(square);
    NSURL *flat = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"pager-flat.pdf"]];
    XCTAssertTrue([source writeFlattenedSession:session toURL:flat error:&error], @"%@", error);
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
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
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

- (void)testMacDocumentViewUsesTiledLayerAndDraws {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"pager-view-test.pdf"]];
    XCTAssertTrue([PDFWithHello(0) writeToURL:url atomically:YES]);
    PagerDocument *document = [[PagerDocument alloc] init];
    NSError *error = nil;
    XCTAssertTrue([document readFromURL:url ofType:@"pdf" error:&error], @"%@", error);

    PagerDocumentView *view = [[PagerDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 800, 1000)];
    [view attachToDocument:document];

    // The canvas must be backed by a single-level, synchronously drawn CATiledLayer so long
    // documents never exceed backing-store limits.
    XCTAssertTrue([view.layer isKindOfClass:[CATiledLayer class]]);
    CATiledLayer *layer = (CATiledLayer *)view.layer;
    XCTAssertEqual(layer.levelsOfDetail, 1);
    XCTAssertEqual(layer.levelsOfDetailBias, 0);
    XCTAssertFalse(layer.drawsAsynchronously);
    XCTAssertEqualWithAccuracy(layer.tileSize.width, 256, 0.1);
    XCTAssertEqualWithAccuracy([[view.layer class] fadeDuration], 0, 0.001);
    XCTAssertTrue(view.isFlipped);

    // drawRect must produce both the gray surround and the white page.
    [view syncFrameAndTiles];
    const NSRect region = NSMakeRect(0, 0, 400, 300);
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:region];
    XCTAssertNotNil(rep);
    [view cacheDisplayInRect:region toBitmapImageRep:rep];
    BOOL sawWhite = NO;
    BOOL sawGray = NO;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 7) {
        for (NSInteger x = 0; x < rep.pixelsWide; x += 7) {
            NSColor *color = [rep colorAtX:x y:y];
            const CGFloat brightness = color.redComponent;  // drawing is grayscale here
            sawWhite = sawWhite || brightness > 0.95;
            sawGray = sawGray || (brightness > 0.80 && brightness < 0.95);
        }
    }
    XCTAssertTrue(sawWhite);
    XCTAssertTrue(sawGray);
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
    session.eraseAt(0, page, pager::Point{80, 70}, 8);
    XCTAssertEqual(session.notes().annotations().size(), 0u);
    XCTAssertTrue(session.notes().find(textId) == nullptr);
}

@end
