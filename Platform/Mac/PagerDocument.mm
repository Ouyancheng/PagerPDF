#import "PagerDocument.h"

#import "NoteArchive.h"
#import "PagerWindowController.h"

#import <PDFKit/PDFKit.h>

#include <algorithm>
#include <memory>
#include <mutex>

namespace {

constexpr double kSaveDelay = 0.4;

PagerOutlineNode *NodeFromItem(const pager::OutlineItem &item) {
    PagerOutlineNode *node = [[PagerOutlineNode alloc] init];
    node.title = @(item.title.c_str()) ?: @"";
    node.page = item.pageIndex;
    node.x = item.point.x;
    node.y = item.point.y;
    NSMutableArray<PagerOutlineNode *> *children = [NSMutableArray array];
    for (const pager::OutlineItem &child : item.children) {
        [children addObject:NodeFromItem(child)];
    }
    node.children = children;
    return node;
}

}  // namespace

@implementation PagerOutlineNode
@end

@implementation PagerDocument {
    pager::DocumentSession _session;
    PDFKitPageSource *_source;
    NSArray<PagerOutlineNode *> *_outline;
    BOOL _accessing;
    dispatch_queue_t _saveQueue;
    BOOL _saveScheduled;
    std::uint64_t _savedRevision;
    std::mutex _thumbnailMutex;
    PDFDocument *_thumbnailDocument;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _source = [[PDFKitPageSource alloc] init];
        _outline = @[];
        _saveQueue = dispatch_queue_create("pager.notes.save", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    // Render threads borrow _source's raster source; join them before ivars are destroyed.
    _session.viewport().stop();
}

+ (BOOL)autosavesInPlace {
    return NO;
}

- (pager::DocumentSession &)session {
    return _session;
}

- (PDFKitPageSource *)source {
    return _source;
}

- (NSArray<PagerOutlineNode *> *)outline {
    return _outline;
}

- (void)makeWindowControllers {
    [self addWindowController:[[PagerWindowController alloc] initWithDocument:self]];
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
    _accessing = [url startAccessingSecurityScopedResource];
    if (![_source openURL:url password:nil error:outError]) {
        if (_accessing) {
            [url stopAccessingSecurityScopedResource];
            _accessing = NO;
        }
        return NO;
    }
    std::vector<pager::PageGeometry> pages;
    for (NSInteger index = 0; index < _source.pageCount; ++index) {
        pages.push_back([_source geometryAtIndex:index]);
    }
    _session.viewport().setPages(std::move(pages));
    _session.viewport().setSource(_source.rasterSource);
    _session.imported = [_source importAnnotations];
    pager::NoteDocument loaded;
    [PagerNoteArchive loadDocument:loaded pdfURL:url error:nil];
    _session.notes().replaceAll(loaded.annotations());
    _savedRevision = _session.notes().revision();
    NSMutableArray<PagerOutlineNode *> *outline = [NSMutableArray array];
    for (const pager::OutlineItem &item : [_source outlineItems]) {
        [outline addObject:NodeFromItem(item)];
    }
    _outline = outline;
    return YES;
}

- (void)saveNotes {
    if (_saveScheduled) {
        return;
    }
    _saveScheduled = YES;
    __weak PagerDocument *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kSaveDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf flushNotes];
                   });
}

- (void)flushNotes {
    _saveScheduled = NO;
    const std::uint64_t revision = _session.notes().revision();
    if (revision == _savedRevision || self.fileURL == nil) {
        return;
    }
    _savedRevision = revision;
    auto copy = std::make_shared<std::vector<pager::Annotation>>(_session.notes().annotations());
    NSURL *url = self.fileURL;
    dispatch_async(_saveQueue, ^{
        [PagerNoteArchive saveAnnotations:*copy pdfURL:url error:nil];
    });
}

- (void)flushNotesAndWait {
    [self flushNotes];
    dispatch_sync(_saveQueue, ^{
                  });
}

- (void)close {
    [self flushNotesAndWait];
    [_source cancelSearch];
    _session.viewport().stop();
    if (_accessing) {
        [self.fileURL stopAccessingSecurityScopedResource];
        _accessing = NO;
    }
    [super close];
}

- (void)exportAnnotatedPDFToURL:(NSURL *)url completion:(void (^)(BOOL success, NSError *error))completion {
    auto notes = std::make_shared<std::vector<pager::Annotation>>(_session.notes().annotations());
    PDFKitPageSource *source = _source;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        const BOOL written = [source writeFlattenedNotes:*notes toURL:url error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(written, error);
        });
    });
}

- (CGImageRef)copyThumbnailForPage:(NSInteger)page maxPixels:(CGFloat)maxPixels {
    std::lock_guard<std::mutex> guard(_thumbnailMutex);
    if (_thumbnailDocument == nil && self.fileURL != nil) {
        _thumbnailDocument = [[PDFDocument alloc] initWithURL:self.fileURL];
    }
    if (page < 0 || page >= static_cast<NSInteger>(_thumbnailDocument.pageCount)) {
        return nullptr;
    }
    @autoreleasepool {
        PDFPage *pdfPage = [_thumbnailDocument pageAtIndex:static_cast<NSUInteger>(page)];
        const CGRect bounds = [pdfPage boundsForBox:kPDFDisplayBoxCropBox];
        const NSInteger rotation = ((pdfPage.rotation % 360) + 360) % 360;
        const bool swapped = rotation == 90 || rotation == 270;
        const CGFloat width = swapped ? bounds.size.height : bounds.size.width;
        const CGFloat height = swapped ? bounds.size.width : bounds.size.height;
        const CGFloat scale = maxPixels / std::max<CGFloat>(1, std::max(width, height));
        const size_t pixelWidth = static_cast<size_t>(std::max<CGFloat>(1, width * scale));
        const size_t pixelHeight = static_cast<size_t>(std::max<CGFloat>(1, height * scale));
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(nullptr, pixelWidth, pixelHeight, 8, 0, space,
                                                     static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipFirst) |
                                                         static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little));
        CGColorSpaceRelease(space);
        if (context == nullptr) {
            return nullptr;
        }
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, pixelWidth, pixelHeight));
        CGContextScaleCTM(context, pixelWidth / width, pixelHeight / height);
        [pdfPage drawWithBox:kPDFDisplayBoxCropBox toContext:context];
        CGImageRef image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        return image;
    }
}

@end
