#import "PadDocument.h"

#import "NoteArchive.h"

#include <memory>

namespace {

constexpr double kSaveDelay = 0.4;

void AppendOutline(const pager::OutlineItem &item, NSInteger depth, NSMutableArray<NSDictionary *> *output) {
    [output addObject:@{
        @"title" : @(item.title.c_str()) ?: @"",
        @"page" : @(item.pageIndex),
        @"x" : @(item.point.x),
        @"y" : @(item.point.y),
        @"depth" : @(depth),
    }];
    for (const pager::OutlineItem &child : item.children) {
        AppendOutline(child, depth + 1, output);
    }
}

}  // namespace

@implementation PadDocument {
    pager::DocumentSession _session;
    PDFKitPageSource *_source;
    NSData *_originalData;
    NSMutableArray<NSDictionary *> *_outline;
    BOOL _accessing;
    dispatch_queue_t _saveQueue;
    BOOL _saveScheduled;
    std::uint64_t _savedRevision;
}

- (instancetype)initWithFileURL:(NSURL *)url {
    self = [super initWithFileURL:url];
    if (self != nil) {
        // Access must start before UIDocument's coordinated read, not inside loadFromContents:.
        _accessing = [url startAccessingSecurityScopedResource];
        _source = [[PDFKitPageSource alloc] init];
        _outline = [NSMutableArray array];
        _saveQueue = dispatch_queue_create("pager.notes.save", DISPATCH_QUEUE_SERIAL);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Render threads borrow _source's raster source; they must be joined before ivars
    // (including _source) are destroyed.
    _session.viewport().stop();
}

- (pager::DocumentSession &)session {
    return _session;
}

- (PDFKitPageSource *)source {
    return _source;
}

- (NSArray<NSDictionary *> *)flattenedOutline {
    return _outline;
}

- (BOOL)loadFromContents:(id)contents ofType:(NSString *)typeName error:(NSError **)outError {
    if ([contents isKindOfClass:[NSData class]]) {
        _originalData = contents;
    }
    BOOL opened = [_source openURL:self.fileURL password:nil error:outError];
    if (!opened && _originalData != nil) {
        opened = [_source openData:_originalData error:outError];
    }
    if (!opened) {
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
    [PagerNoteArchive loadDocument:loaded pdfURL:self.fileURL error:nil];
    _session.notes().replaceAll(loaded.annotations());
    _savedRevision = _session.notes().revision();
    _outline = [NSMutableArray array];
    for (const pager::OutlineItem &item : [_source outlineItems]) {
        AppendOutline(item, 0, _outline);
    }
    return YES;
}

- (id)contentsForType:(NSString *)typeName error:(NSError **)outError {
    return _originalData ?: [NSData data];
}

// Coalesces bursts of edits into one write, encoded and written off the main thread.
- (void)saveNotes {
    if (_saveScheduled) {
        return;
    }
    _saveScheduled = YES;
    __weak PadDocument *weakSelf = self;
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

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [self flushNotesAndWait];
}

- (void)closeWithCompletionHandler:(void (^)(BOOL))completionHandler {
    [self flushNotesAndWait];
    [_source cancelSearch];
    _session.viewport().stop();
    if (_accessing) {
        [self.fileURL stopAccessingSecurityScopedResource];
        _accessing = NO;
    }
    [super closeWithCompletionHandler:completionHandler];
}

@end
