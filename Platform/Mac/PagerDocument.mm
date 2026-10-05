#import "PagerDocument.h"

#import "NoteArchive.h"
#import "OverlayRenderer.h"
#import "PagerDocumentView.h"
#import "Zoom.hpp"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>

@interface OutlineNode : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSInteger page;
@property(nonatomic) double x;
@property(nonatomic) double y;
@property(nonatomic, strong) NSMutableArray<OutlineNode *> *children;
@end

@implementation OutlineNode
@end

namespace {

OutlineNode *NodeFromItem(const pager::OutlineItem &item) {
    OutlineNode *node = [[OutlineNode alloc] init];
    node.title = @(item.title.c_str());
    node.page = item.pageIndex;
    node.x = item.point.x;
    node.y = item.point.y;
    node.children = [NSMutableArray array];
    for (const pager::OutlineItem &child : item.children) {
        [node.children addObject:NodeFromItem(child)];
    }
    return node;
}

NSString *KindLabel(pager::AnnotationKind kind) {
    return @(pager::AnnotationKindName(kind));
}

NSImage *Symbol(NSString *name) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
    if (image == nil) {
        image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
        [image lockFocus];
        [[NSColor labelColor] setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(3, 3, 12, 12)];
        path.lineWidth = 1.5;
        [path stroke];
        [image unlockFocus];
    }
    [image setTemplate:YES];
    return image;
}

const pager::Tool kTools[] = {
    pager::Tool::Scroll,     pager::Tool::SelectNote, pager::Tool::SelectText, pager::Tool::Highlight,
    pager::Tool::Underline,  pager::Tool::StrikeOut,  pager::Tool::Square,     pager::Tool::Circle,
    pager::Tool::Line,       pager::Tool::FreeText,   pager::Tool::Pen,        pager::Tool::Marker,
    pager::Tool::Eraser,
};

}  // namespace

@implementation PagerDocument {
    pager::DocumentSession _session;
    PDFKitPageSource *_source;
    PagerDocumentView *_documentView;
    NSScrollView *_scrollView;
    NSOutlineView *_outlineView;
    NSTableView *_notesTable;
    NSToolbarItemGroup *_toolGroup;
    NSSearchField *_searchField;
    NSScrollView *_outlineScroll;
    NSScrollView *_notesScroll;
    NSSegmentedControl *_sidebarControl;
    NSView *_sidebar;
    NSLayoutConstraint *_sidebarWidth;
    NSLayoutConstraint *_scrollLeadingSidebar;
    NSLayoutConstraint *_scrollLeadingEdge;
    NSMutableArray<OutlineNode *> *_outlineNodes;
    BOOL _accessing;
    BOOL _syncingSelection;
    BOOL _sidebarVisible;
}

- (pager::DocumentSession &)session {
    return _session;
}

- (PDFKitPageSource *)source {
    return _source;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _source = [[PDFKitPageSource alloc] init];
        _outlineNodes = [NSMutableArray array];
    }
    return self;
}

- (void)close {
    [_documentView detachViewport];
    if (_accessing) {
        [self.fileURL stopAccessingSecurityScopedResource];
        _accessing = NO;
    }
    [super close];
}

- (void)makeWindowControllers {
    NSRect frame = NSMakeRect(0, 0, 1280, 840);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                                              NSWindowStyleMaskFullSizeContentView
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    window.title = self.displayName ?: @"PagerPDF";
    window.titlebarAppearsTransparent = YES;
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"PagerPDF"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = YES;
    window.toolbar = toolbar;

    _outlineView = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    NSTableColumn *outlineColumn = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    outlineColumn.title = @"Contents";
    outlineColumn.width = 220;
    [_outlineView addTableColumn:outlineColumn];
    _outlineView.outlineTableColumn = outlineColumn;
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.headerView = nil;
    _outlineView.style = NSTableViewStyleSourceList;
    _outlineView.rowHeight = 24;
    _outlineScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _outlineScroll.documentView = _outlineView;
    _outlineScroll.hasVerticalScroller = YES;
    _outlineScroll.drawsBackground = NO;
    _outlineScroll.translatesAutoresizingMaskIntoConstraints = NO;

    _documentView = [[PagerDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 800, 1000)];
    _scrollView = [[NSScrollView alloc] initWithFrame:frame];
    _scrollView.documentView = _documentView;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.drawsBackground = YES;
    _scrollView.backgroundColor = [NSColor colorWithWhite:pager::kCanvasGray alpha:1];
    _scrollView.allowsMagnification = YES;
    _scrollView.minMagnification = 0.25;
    _scrollView.maxMagnification = 8;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.contentView.postsBoundsChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(visibleBoundsChanged:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:_scrollView.contentView];

    _notesTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    NSTableColumn *pageColumn = [[NSTableColumn alloc] initWithIdentifier:@"page"];
    pageColumn.title = @"Page";
    pageColumn.width = 44;
    NSTableColumn *kindColumn = [[NSTableColumn alloc] initWithIdentifier:@"kind"];
    kindColumn.title = @"Kind";
    kindColumn.width = 72;
    NSTableColumn *textColumn = [[NSTableColumn alloc] initWithIdentifier:@"text"];
    textColumn.title = @"Note";
    textColumn.width = 110;
    [_notesTable addTableColumn:pageColumn];
    [_notesTable addTableColumn:kindColumn];
    [_notesTable addTableColumn:textColumn];
    _notesTable.dataSource = self;
    _notesTable.delegate = self;
    _notesTable.style = NSTableViewStyleSourceList;
    _notesTable.headerView = nil;
    _notesTable.rowHeight = 24;
    _notesScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _notesScroll.documentView = _notesTable;
    _notesScroll.hasVerticalScroller = YES;
    _notesScroll.drawsBackground = NO;
    _notesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _notesScroll.hidden = YES;

    _sidebarControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Contents", @"Notes"]
                                                        trackingMode:NSSegmentSwitchTrackingSelectOne
                                                              target:self
                                                              action:@selector(sidebarChanged:)];
    _sidebarControl.selectedSegment = 0;
    _sidebarControl.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *sidebarBody = [[NSView alloc] initWithFrame:NSZeroRect];
    sidebarBody.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebarBody addSubview:_sidebarControl];
    [sidebarBody addSubview:_outlineScroll];
    [sidebarBody addSubview:_notesScroll];
    [NSLayoutConstraint activateConstraints:@[
        [_sidebarControl.topAnchor constraintEqualToAnchor:sidebarBody.topAnchor constant:10],
        [_sidebarControl.leadingAnchor constraintEqualToAnchor:sidebarBody.leadingAnchor constant:10],
        [_sidebarControl.trailingAnchor constraintEqualToAnchor:sidebarBody.trailingAnchor constant:-10],
        [_outlineScroll.topAnchor constraintEqualToAnchor:_sidebarControl.bottomAnchor constant:8],
        [_outlineScroll.leadingAnchor constraintEqualToAnchor:sidebarBody.leadingAnchor],
        [_outlineScroll.trailingAnchor constraintEqualToAnchor:sidebarBody.trailingAnchor],
        [_outlineScroll.bottomAnchor constraintEqualToAnchor:sidebarBody.bottomAnchor],
        [_notesScroll.topAnchor constraintEqualToAnchor:_outlineScroll.topAnchor],
        [_notesScroll.leadingAnchor constraintEqualToAnchor:_outlineScroll.leadingAnchor],
        [_notesScroll.trailingAnchor constraintEqualToAnchor:_outlineScroll.trailingAnchor],
        [_notesScroll.bottomAnchor constraintEqualToAnchor:_outlineScroll.bottomAnchor],
    ]];

    NSView *sidebar = nil;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        glass.style = NSGlassEffectViewStyleRegular;
        glass.cornerRadius = 20;
        glass.contentView = sidebarBody;
        sidebar = glass;
    }
    if (sidebar == nil) {
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        effect.material = NSVisualEffectMaterialSidebar;
        effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        effect.state = NSVisualEffectStateFollowsWindowActiveState;
        effect.wantsLayer = YES;
        effect.layer.cornerRadius = 20;
        effect.layer.masksToBounds = YES;
        [effect addSubview:sidebarBody];
        [NSLayoutConstraint activateConstraints:@[
            [sidebarBody.topAnchor constraintEqualToAnchor:effect.topAnchor],
            [sidebarBody.leadingAnchor constraintEqualToAnchor:effect.leadingAnchor],
            [sidebarBody.trailingAnchor constraintEqualToAnchor:effect.trailingAnchor],
            [sidebarBody.bottomAnchor constraintEqualToAnchor:effect.bottomAnchor],
        ]];
        sidebar = effect;
    }
    sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    _sidebar = sidebar;
    _sidebarVisible = YES;
    if ([NSUserDefaults.standardUserDefaults objectForKey:@"PagerSidebarVisible"] != nil) {
        _sidebarVisible = [NSUserDefaults.standardUserDefaults boolForKey:@"PagerSidebarVisible"];
    }

    NSView *root = [[NSView alloc] initWithFrame:frame];
    [root addSubview:_scrollView];
    [root addSubview:sidebar];
    window.contentView = root;
    _sidebarWidth = [sidebar.widthAnchor constraintEqualToConstant:_sidebarVisible ? 276 : 0];
    _scrollLeadingSidebar = [_scrollView.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:8];
    _scrollLeadingEdge = [_scrollView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor];
    sidebar.hidden = !_sidebarVisible;
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:8],
        [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],
        [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-12],
        _sidebarWidth,
    ]];
    _scrollLeadingSidebar.active = _sidebarVisible;
    _scrollLeadingEdge.active = !_sidebarVisible;

    NSWindowController *controller = [[NSWindowController alloc] initWithWindow:window];
    [self addWindowController:controller];
    [_documentView attachToDocument:self];
    [window makeFirstResponder:_documentView];
    _session.viewport().setScreenScale(window.backingScaleFactor ?: 2);
    [_documentView syncFrameAndTiles];
    [_outlineView reloadData];
    [_notesTable reloadData];
}

- (void)visibleBoundsChanged:(NSNotification *)notification {
    _session.viewport().setScale(pager::ClampScale(_scrollView.magnification));
    [_documentView updateVisibleRect];
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
    _session.imported = [_source importAnnotations];
    pager::NoteDocument loaded;
    [PagerNoteArchive loadDocument:loaded pdfURL:url error:nil];
    _session.notes().replaceAll(loaded.annotations());
    _outlineNodes = [NSMutableArray array];
    for (const pager::OutlineItem &item : [_source outlineItems]) {
        [_outlineNodes addObject:NodeFromItem(item)];
    }
    return YES;
}

- (void)notesDidChange {
    [PagerNoteArchive saveDocument:_session.notes() pdfURL:self.fileURL error:nil];
    [self syncNoteSelection];
}

- (void)syncNoteSelection {
    _syncingSelection = YES;
    [_notesTable reloadData];
    NSInteger selectedRow = -1;
    const pager::AnnotationId selected = _session.selectedNote();
    const auto &notes = _session.notes().annotations();
    for (NSInteger row = 0; row < static_cast<NSInteger>(notes.size()); ++row) {
        if (notes[static_cast<std::size_t>(row)].id == selected) {
            selectedRow = row;
            break;
        }
    }
    if (selectedRow >= 0) {
        [_notesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(selectedRow)] byExtendingSelection:NO];
    } else {
        [_notesTable deselectAll:nil];
    }
    _syncingSelection = NO;
    [_documentView setNeedsDisplay:YES];
}

- (IBAction)sidebarChanged:(NSSegmentedControl *)sender {
    const BOOL notes = sender.selectedSegment == 1;
    _outlineScroll.hidden = notes;
    _notesScroll.hidden = !notes;
}

- (IBAction)toggleSidebar:(id)sender {
    _sidebarVisible = !_sidebarVisible;
    [NSUserDefaults.standardUserDefaults setBool:_sidebarVisible forKey:@"PagerSidebarVisible"];
    _sidebarWidth.constant = _sidebarVisible ? 276 : 0;
    _scrollLeadingSidebar.active = _sidebarVisible;
    _scrollLeadingEdge.active = !_sidebarVisible;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        self->_sidebar.animator.hidden = !self->_sidebarVisible;
        [self->_sidebar.superview layoutSubtreeIfNeeded];
    }];
    [_documentView updateVisibleRect];
}

- (IBAction)deleteNote:(id)sender {
    if (_session.deleteSelectedNote()) {
        [self notesDidChange];
    }
}

- (void)scrollToPage:(int)page userPoint:(pager::Point)point {
    const pager::PageGeometry *geometry = _session.viewport().geometry(page);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point documentPoint =
        _session.viewport().layout().pageViewToDocument(page, pager::UserToPageView(*geometry, point));
    [_documentView scrollRectToVisible:NSMakeRect(documentPoint.x - 40, documentPoint.y - 80, 120, 160)];
    [_documentView updateVisibleRect];
}

- (void)commitZoomFactor:(double)factor anchorInDocument:(pager::Point)anchor {
    const double next = pager::ClampScale(_scrollView.magnification * factor);
    [_scrollView setMagnification:next centeredAtPoint:NSMakePoint(anchor.x, anchor.y)];
    _session.viewport().setScale(next);
    [_documentView updateVisibleRect];
}

- (IBAction)toolChanged:(id)sender {
    const NSInteger index = _toolGroup.selectedIndex;
    if (index < 0 || index >= static_cast<NSInteger>(sizeof(kTools) / sizeof(kTools[0]))) {
        return;
    }
    _session.setTool(kTools[index]);
    [self.windowControllers.firstObject.window makeFirstResponder:_documentView];
}

- (IBAction)searchChanged:(NSSearchField *)sender {
    NSString *query = sender.stringValue ?: @"";
    if (query.length == 0) {
        _session.clearSearch();
        [_documentView setNeedsDisplay:YES];
        return;
    }
    _session.setSearchHits([_source findString:query]);
    const pager::TextSelection *hit = _session.currentSearchHit();
    if (hit != nullptr && !hit->quads.empty()) {
        const pager::Point anchor = hit->quads.front().quad.v[0];
        [self scrollToPage:hit->quads.front().pageIndex userPoint:anchor];
    }
    [_documentView setNeedsDisplay:YES];
}

- (IBAction)findNext:(id)sender {
    if (_session.advanceSearch(1)) {
        const pager::TextSelection *hit = _session.currentSearchHit();
        if (hit != nullptr && !hit->quads.empty()) {
            [self scrollToPage:hit->quads.front().pageIndex userPoint:hit->quads.front().quad.v[0]];
        }
        [_documentView setNeedsDisplay:YES];
    }
}

- (IBAction)zoomIn:(id)sender {
    const NSRect visible = _scrollView.documentVisibleRect;
    [self commitZoomFactor:1.25 anchorInDocument:pager::Point{NSMidX(visible), NSMidY(visible)}];
}

- (IBAction)zoomOut:(id)sender {
    const NSRect visible = _scrollView.documentVisibleRect;
    [self commitZoomFactor:0.8 anchorInDocument:pager::Point{NSMidX(visible), NSMidY(visible)}];
}

- (IBAction)exportFlattened:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePDF];
    panel.nameFieldStringValue = @"Flattened.pdf";
    if ([panel runModal] != NSModalResponseOK) {
        return;
    }
    NSError *error = nil;
    if (![_source writeFlattenedSession:_session toURL:panel.URL error:&error]) {
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert runModal];
    }
}

- (void)copy:(id)sender {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:@(_session.selection().text.c_str()) forType:NSPasteboardTypeString];
}

- (void)undo:(id)sender {
    _session.notes().undo();
    [self notesDidChange];
}

- (void)redo:(id)sender {
    _session.notes().redo();
    [self notesDidChange];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if (item.action == @selector(undo:)) {
        return _session.notes().canUndo();
    }
    if (item.action == @selector(redo:)) {
        return _session.notes().canRedo();
    }
    if (item.action == @selector(deleteNote:)) {
        return _session.selectedNote().value != 0;
    }
    return YES;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"sidebar", @"tools", @"search", @"delete", NSToolbarSpaceItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"sidebar", @"tools", NSToolbarSpaceItemIdentifier, @"delete", NSToolbarFlexibleSpaceItemIdentifier, @"search"];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:@"tools"]) {
        NSArray<NSImage *> *images = @[
            Symbol(@"hand.raised"), Symbol(@"cursorarrow"), Symbol(@"character.cursor.ibeam"), Symbol(@"highlighter"),
            Symbol(@"underline"), Symbol(@"strikethrough"), Symbol(@"rectangle"), Symbol(@"circle"), Symbol(@"line.diagonal"),
            Symbol(@"note.text"), Symbol(@"pencil.tip"), Symbol(@"paintbrush.pointed"), Symbol(@"eraser"),
        ];
        NSArray<NSString *> *labels = @[
            @"Scroll", @"Select Note", @"Select Text", @"Highlight", @"Underline", @"Strikeout", @"Box", @"Circle", @"Line",
            @"Text Note", @"Pen", @"Marker", @"Eraser",
        ];
        _toolGroup = [NSToolbarItemGroup groupWithItemIdentifier:itemIdentifier
                                                          images:images
                                                   selectionMode:NSToolbarItemGroupSelectionModeSelectOne
                                                          labels:labels
                                                          target:self
                                                          action:@selector(toolChanged:)];
        _toolGroup.selectedIndex = 0;
        _toolGroup.label = @"Tools";
        return _toolGroup;
    }
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    if ([itemIdentifier isEqualToString:@"sidebar"]) {
        item.image = Symbol(@"sidebar.leading");
        item.label = @"Sidebar";
        item.toolTip = @"Hide or show the contents and notes pane";
        item.action = @selector(toggleSidebar:);
        item.target = self;
        return item;
    }
    if ([itemIdentifier isEqualToString:@"search"]) {
        _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 220, 28)];
        _searchField.placeholderString = @"Find";
        _searchField.target = self;
        _searchField.action = @selector(searchChanged:);
        item.view = _searchField;
        item.label = @"Find";
    } else if ([itemIdentifier isEqualToString:@"delete"]) {
        item.image = Symbol(@"trash");
        item.label = @"Delete Note";
        item.toolTip = @"Delete the selected note";
        item.action = @selector(deleteNote:);
        item.target = self;
    }
    return item;
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (item == nil) {
        return _outlineNodes.count;
    }
    return ((OutlineNode *)item).children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (item == nil) {
        return _outlineNodes[static_cast<NSUInteger>(index)];
    }
    return ((OutlineNode *)item).children[static_cast<NSUInteger>(index)];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return ((OutlineNode *)item).children.count > 0;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item {
    return ((OutlineNode *)item).title;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    OutlineNode *node = [_outlineView itemAtRow:_outlineView.selectedRow];
    if (node != nil && node.page >= 0) {
        [self scrollToPage:static_cast<int>(node.page) userPoint:pager::Point{node.x, node.y}];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(_session.notes().annotations().size());
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    const pager::Annotation &note = _session.notes().annotations()[static_cast<std::size_t>(row)];
    if ([tableColumn.identifier isEqualToString:@"page"]) {
        return [NSString stringWithFormat:@"%d", note.pageIndex + 1];
    }
    if ([tableColumn.identifier isEqualToString:@"kind"]) {
        return KindLabel(note.kind);
    }
    if (!note.contents.empty()) {
        return @(note.contents.c_str());
    }
    return KindLabel(note.kind);
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_syncingSelection || notification.object != _notesTable) {
        return;
    }
    const NSInteger row = _notesTable.selectedRow;
    if (row < 0 || row >= static_cast<NSInteger>(_session.notes().annotations().size())) {
        _session.setSelectedNote({});
        [_documentView setNeedsDisplay:YES];
        return;
    }
    const pager::Annotation &note = _session.notes().annotations()[static_cast<std::size_t>(row)];
    _session.setSelectedNote(note.id);
    [_documentView setNeedsDisplay:YES];
    [self scrollToPage:note.pageIndex userPoint:pager::Point{note.bounds.x, note.bounds.y + note.bounds.height}];
}

@end
