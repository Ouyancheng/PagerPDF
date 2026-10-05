#import "PadDocument.h"

#import "NoteArchive.h"

namespace {

void AppendOutline(const pager::OutlineItem &item, NSInteger depth, NSMutableArray<NSDictionary *> *output) {
    [output addObject:@{
        @"title" : @(item.title.c_str()),
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
}

- (instancetype)initWithFileURL:(NSURL *)url {
    self = [super initWithFileURL:url];
    if (self != nil) {
        // Access must start before UIDocument's coordinated read, not inside loadFromContents:.
        _accessing = [url startAccessingSecurityScopedResource];
        _source = [[PDFKitPageSource alloc] init];
        _outline = [NSMutableArray array];
    }
    return self;
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
    _session.imported = [_source importAnnotations];
    pager::NoteDocument loaded;
    [PagerNoteArchive loadDocument:loaded pdfURL:self.fileURL error:nil];
    _session.notes().replaceAll(loaded.annotations());
    _outline = [NSMutableArray array];
    for (const pager::OutlineItem &item : [_source outlineItems]) {
        AppendOutline(item, 0, _outline);
    }
    return YES;
}

- (id)contentsForType:(NSString *)typeName error:(NSError **)outError {
    return _originalData ?: [NSData data];
}

- (void)saveNotes {
    [PagerNoteArchive saveDocument:_session.notes() pdfURL:self.fileURL error:nil];
}

- (void)closeWithCompletionHandler:(void (^)(BOOL))completionHandler {
    if (_accessing) {
        [self.fileURL stopAccessingSecurityScopedResource];
        _accessing = NO;
    }
    [super closeWithCompletionHandler:completionHandler];
}

@end
