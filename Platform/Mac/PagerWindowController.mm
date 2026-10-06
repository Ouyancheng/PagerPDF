#import "PagerWindowController.h"

#import "OverlayRenderer.h"
#import "PagerCanvasView.h"
#import "PagerDocument.h"
#import "ToolPalette.hpp"

#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <unordered_map>

namespace {

NSString *const kToolbarPages = @"pager.pages";
NSString *const kToolbarZoom = @"pager.zoom";
NSString *const kToolbarShare = @"pager.share";
NSString *const kToolbarSearch = @"pager.search";
NSString *const kSidebarModeKey = @"PagerSidebarMode";

enum SidebarMode : NSInteger {
    kSidebarThumbnails = 0,
    kSidebarContents = 1,
    kSidebarNotes = 2,
};

struct ToolEntry {
    pager::Tool tool;
    NSString *symbol;
    NSString *label;
    NSString *shortcut;
};

const ToolEntry kTools[] = {
    {pager::Tool::Scroll, @"cursorarrow", @"Select", @"V"},
    {pager::Tool::SelectText, @"character.cursor.ibeam", @"Text Selection", nil},
    {pager::Tool::Highlight, @"highlighter", @"Highlight", @"H"},
    {pager::Tool::Underline, @"underline", @"Underline", @"U"},
    {pager::Tool::StrikeOut, @"strikethrough", @"Strikethrough", @"K"},
    {pager::Tool::Pen, @"pencil.tip", @"Pen", @"P"},
    {pager::Tool::Marker, @"paintbrush.pointed", @"Marker", @"M"},
    {pager::Tool::Eraser, @"eraser", @"Eraser", @"E"},
    {pager::Tool::Square, @"rectangle", @"Rectangle", @"R"},
    {pager::Tool::Circle, @"circle", @"Oval", @"O"},
    {pager::Tool::Line, @"line.diagonal", @"Line", @"L"},
    {pager::Tool::FreeText, @"character.textbox", @"Text Box", @"T"},
};
constexpr NSInteger kToolCount = sizeof(kTools) / sizeof(kTools[0]);

NSInteger SegmentForTool(pager::Tool tool) {
    for (NSInteger index = 0; index < kToolCount; ++index) {
        if (kTools[index].tool == tool) {
            return index;
        }
    }
    return 0;
}

NSImage *Symbol(NSString *name, NSString *label) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:label] ?: [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
}

NSImage *Swatch(pager::Color color, CGFloat size) {
    return [NSImage imageWithSize:NSMakeSize(size, size)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1.5, 1.5)];
                       [[NSColor colorWithSRGBRed:color.r green:color.g blue:color.b alpha:std::max(0.45f, color.a)] setFill];
                       [dot fill];
                       [[NSColor.labelColor colorWithAlphaComponent:0.25] setStroke];
                       dot.lineWidth = 0.5;
                       [dot stroke];
                       return YES;
                   }];
}

NSString *ColorName(pager::Color color) {
    NSColor *rgb = [NSColor colorWithSRGBRed:color.r green:color.g blue:color.b alpha:1];
    const CGFloat hue = rgb.hueComponent * 360;
    const CGFloat saturation = rgb.saturationComponent;
    const CGFloat brightness = rgb.brightnessComponent;
    if (saturation < 0.15) {
        return brightness < 0.2 ? @"Black" : (brightness < 0.75 ? @"Gray" : @"White");
    }
    if (hue < 15 || hue >= 345) {
        return @"Red";
    }
    if (hue < 40) {
        return @"Orange";
    }
    if (hue < 70) {
        return @"Yellow";
    }
    if (hue < 170) {
        return @"Green";
    }
    if (hue < 255) {
        return @"Blue";
    }
    if (hue < 300) {
        return @"Purple";
    }
    return @"Pink";
}

NSString *KindTitle(pager::AnnotationKind kind) {
    switch (kind) {
        case pager::AnnotationKind::Highlight:
            return @"Highlight";
        case pager::AnnotationKind::Underline:
            return @"Underline";
        case pager::AnnotationKind::StrikeOut:
            return @"Strikethrough";
        case pager::AnnotationKind::Square:
            return @"Rectangle";
        case pager::AnnotationKind::Circle:
            return @"Oval";
        case pager::AnnotationKind::Line:
            return @"Line";
        case pager::AnnotationKind::FreeText:
            return @"Text Box";
        case pager::AnnotationKind::Ink:
            return @"Drawing";
    }
    return @"Note";
}

NSString *KindSymbol(pager::AnnotationKind kind) {
    switch (kind) {
        case pager::AnnotationKind::Highlight:
            return @"highlighter";
        case pager::AnnotationKind::Underline:
            return @"underline";
        case pager::AnnotationKind::StrikeOut:
            return @"strikethrough";
        case pager::AnnotationKind::Square:
            return @"rectangle";
        case pager::AnnotationKind::Circle:
            return @"circle";
        case pager::AnnotationKind::Line:
            return @"line.diagonal";
        case pager::AnnotationKind::FreeText:
            return @"character.textbox";
        case pager::AnnotationKind::Ink:
            return @"scribble";
    }
    return @"note.text";
}

// Floating control surface: Liquid Glass on macOS 26, a vibrant rounded panel before it.
NSView *FloatingPanel(NSView *content, CGFloat radius) {
    content.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *panel = nil;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        glass.cornerRadius = radius;
        glass.contentView = content;
        panel = glass;
    } else {
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        effect.material = NSVisualEffectMaterialHUDWindow;
        effect.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        effect.state = NSVisualEffectStateActive;
        effect.wantsLayer = YES;
        effect.layer.cornerRadius = radius;
        effect.layer.masksToBounds = YES;
        [effect addSubview:content];
        panel = effect;
    }
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
    ]];
    return panel;
}

NSScrollView *ScrollFor(NSView *documentView) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = documentView;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    return scroll;
}

}  // namespace

#pragma mark - Window

@protocol PagerNotesUndo <NSObject>
- (BOOL)canUndoNotes:(BOOL)undo;
@end

@implementation PagerWindow

- (BOOL)editingText {
    return [self.firstResponder isKindOfClass:[NSText class]];
}

- (void)undo:(id)sender {
    if ([self editingText]) {
        [self.undoManager undo];
        return;
    }
    [self.windowController tryToPerform:@selector(undoNotes:) with:sender];
}

- (void)redo:(id)sender {
    if ([self editingText]) {
        [self.undoManager redo];
        return;
    }
    [self.windowController tryToPerform:@selector(redoNotes:) with:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(undo:) || item.action == @selector(redo:)) {
        const BOOL undo = item.action == @selector(undo:);
        if ([self editingText]) {
            item.title = undo ? self.undoManager.undoMenuItemTitle : self.undoManager.redoMenuItemTitle;
            return undo ? self.undoManager.canUndo : self.undoManager.canRedo;
        }
        item.title = undo ? @"Undo" : @"Redo";
        id controller = self.windowController;
        return [controller conformsToProtocol:@protocol(PagerNotesUndo)] && [(id<PagerNotesUndo>)controller canUndoNotes:undo];
    }
    return [super validateMenuItem:item];
}

@end

// Keeps a document narrower or shorter than the window centred, as Preview does.
@interface PagerCenteringClipView : NSClipView
@end

@implementation PagerCenteringClipView

- (NSRect)constrainBoundsRect:(NSRect)proposedBounds {
    NSRect bounds = [super constrainBoundsRect:proposedBounds];
    NSView *document = self.documentView;
    if (document != nil) {
        const NSRect frame = document.frame;
        if (bounds.size.width > frame.size.width) {
            bounds.origin.x = (frame.size.width - bounds.size.width) * 0.5;
        }
        if (bounds.size.height > frame.size.height) {
            bounds.origin.y = (frame.size.height - bounds.size.height) * 0.5;
        }
    }
    return bounds;
}

@end

// Hosts the scroll view and the controls floating over it; reports layout so the scroll
// insets can follow the safe area (toolbar) and the floating markup bar.
@interface PagerContentView : NSView
@property(nonatomic, copy) void (^onLayout)(void);
@end

@implementation PagerContentView

- (void)layout {
    [super layout];
    if (self.onLayout != nil) {
        self.onLayout();
    }
}

@end

// Delete in the notes list deletes the note.
@interface PagerNotesTableView : NSTableView
@end

@implementation PagerNotesTableView

- (void)keyDown:(NSEvent *)event {
    const unichar key = event.charactersIgnoringModifiers.length > 0 ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (key == NSDeleteCharacter || key == NSBackspaceCharacter || key == NSDeleteFunctionKey) {
        [NSApp sendAction:@selector(delete:) to:nil from:self];
        return;
    }
    [super keyDown:event];
}

@end

#pragma mark - Window controller

@interface PagerWindowController () <NSToolbarDelegate, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
                                     NSSharingServicePickerToolbarItemDelegate, NSMenuItemValidation, PagerCanvasViewDelegate,
                                     PagerNotesUndo, NSWindowDelegate>
@end

@implementation PagerWindowController {
    __weak PagerDocument *_pagerDocument;
    NSSplitViewController *_split;
    NSSplitViewItem *_sidebarItem;
    NSScrollView *_scrollView;
    PagerCanvasView *_canvas;
    NSSegmentedControl *_sidebarMode;
    NSScrollView *_thumbnailScroll;
    NSTableView *_thumbnailTable;
    NSScrollView *_outlineScroll;
    NSOutlineView *_outlineView;
    NSScrollView *_notesScroll;
    PagerNotesTableView *_notesTable;
    NSTextField *_emptyNotesLabel;
    PagerContentView *_contentRoot;
    NSView *_markupPalette;
    NSView *_pageHUD;
    NSTextField *_pageHUDLabel;
    BOOL _fitsWidth;
    BOOL _fullScreen;
    BOOL _markupVisible;
    NSSegmentedControl *_toolControl;
    NSPopUpButton *_colorPopup;
    NSPopUpButton *_sizePopup;
    NSSearchToolbarItem *_searchItem;
    NSCache<NSNumber *, NSImage *> *_thumbnails;
    std::unordered_map<NSInteger, std::uint64_t> _thumbnailRevisions;
    dispatch_queue_t _thumbnailQueue;
    NSString *_lastQuery;
    BOOL _magnifying;
    BOOL _syncingSelection;
    BOOL _searching;
    std::uint64_t _notesRevisionShown;
    int _currentPage;
}

- (instancetype)initWithDocument:(PagerDocument *)document {
    PagerWindow *window = [[PagerWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 860)
                                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                                   NSWindowStyleMaskMiniaturizable |
                                                                   NSWindowStyleMaskResizable |
                                                                   NSWindowStyleMaskFullSizeContentView
                                                           backing:NSBackingStoreBuffered
                                                             defer:YES];
    self = [super initWithWindow:window];
    if (self != nil) {
        _pagerDocument = document;
        _thumbnails = [[NSCache alloc] init];
        _thumbnails.countLimit = 400;
        _thumbnailQueue = dispatch_queue_create("pager.thumbnails", DISPATCH_QUEUE_SERIAL);
        _currentPage = -1;
        _notesRevisionShown = ~0ull;
        [self buildWindow];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (PagerCanvasView *)canvasView {
    return _canvas;
}

- (NSScrollView *)scrollView {
    return _scrollView;
}

- (pager::DocumentSession *)session {
    PagerDocument *document = _pagerDocument;
    return document == nil ? nullptr : &document.session;
}

#pragma mark - Building the window

- (void)buildWindow {
    NSWindow *window = self.window;
    window.delegate = self;
    window.minSize = NSMakeSize(700, 440);
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    window.tabbingMode = NSWindowTabbingModePreferred;
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    if (@available(macOS 26.0, *)) {
        // Pages run under the toolbar; its glass items and the scroll edge effect keep it legible.
        window.titlebarAppearsTransparent = YES;
    }

    _canvas = [[PagerCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 800, 1000)];
    _canvas.delegate = self;
    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 800, 800)];
    _scrollView.contentView = [[PagerCenteringClipView alloc] initWithFrame:_scrollView.contentView.frame];
    _scrollView.documentView = _canvas;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    _scrollView.drawsBackground = YES;
    _scrollView.backgroundColor = NSColor.underPageBackgroundColor;
    _scrollView.allowsMagnification = YES;
    _scrollView.minMagnification = 0.25;
    _scrollView.maxMagnification = 8;
    _scrollView.contentView.postsBoundsChangedNotifications = YES;
    // Insets are managed by hand so pages can also clear the floating markup bar.
    _scrollView.automaticallyAdjustsContentInsets = NO;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(visibleBoundsChanged:) name:NSViewBoundsDidChangeNotification object:_scrollView.contentView];
    [center addObserver:self selector:@selector(scrollFrameChanged:) name:NSViewFrameDidChangeNotification object:_scrollView];
    [center addObserver:self selector:@selector(liveMagnifyStarted:) name:NSScrollViewWillStartLiveMagnifyNotification object:_scrollView];
    [center addObserver:self selector:@selector(liveMagnifyEnded:) name:NSScrollViewDidEndLiveMagnifyNotification object:_scrollView];

    _contentRoot = [[PagerContentView alloc] initWithFrame:NSMakeRect(0, 0, 800, 800)];
    [_contentRoot addSubview:_scrollView];
    _markupPalette = FloatingPanel([self buildMarkupBar], 20);
    [_contentRoot addSubview:_markupPalette];
    _pageHUDLabel = [NSTextField labelWithString:@""];
    _pageHUDLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _pageHUDLabel.alignment = NSTextAlignmentCenter;
    NSView *hudContent = [[NSView alloc] initWithFrame:NSZeroRect];
    _pageHUDLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [hudContent addSubview:_pageHUDLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_pageHUDLabel.leadingAnchor constraintEqualToAnchor:hudContent.leadingAnchor constant:16],
        [_pageHUDLabel.trailingAnchor constraintEqualToAnchor:hudContent.trailingAnchor constant:-16],
        [_pageHUDLabel.centerYAnchor constraintEqualToAnchor:hudContent.centerYAnchor],
        [hudContent.heightAnchor constraintEqualToConstant:32],
    ]];
    _pageHUD = FloatingPanel(hudContent, 16);
    _pageHUD.alphaValue = 0;
    _pageHUD.hidden = YES;
    [_contentRoot addSubview:_pageHUD];
    NSLayoutGuide *safe = _contentRoot.safeAreaLayoutGuide;
    NSLayoutConstraint *paletteCenter = [_markupPalette.centerXAnchor constraintEqualToAnchor:_contentRoot.centerXAnchor];
    paletteCenter.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.leadingAnchor constraintEqualToAnchor:_contentRoot.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:_contentRoot.trailingAnchor],
        [_scrollView.topAnchor constraintEqualToAnchor:_contentRoot.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_contentRoot.bottomAnchor],
        [_markupPalette.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        paletteCenter,
        [_markupPalette.leadingAnchor constraintGreaterThanOrEqualToAnchor:_contentRoot.leadingAnchor constant:10],
        [_markupPalette.trailingAnchor constraintLessThanOrEqualToAnchor:_contentRoot.trailingAnchor constant:-10],
        [_pageHUD.centerXAnchor constraintEqualToAnchor:_contentRoot.centerXAnchor],
        [_pageHUD.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
    ]];
    __weak PagerWindowController *weakLayout = self;
    _contentRoot.onLayout = ^{
        [weakLayout updateScrollInsets];
    };
    _markupPalette.hidden = YES;
    // The bar wakes up when the pointer comes near it (see -markupRevealZone).
    [_contentRoot addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                               options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                                                                       NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                                 owner:self
                                                              userInfo:nil]];

    NSViewController *content = [[NSViewController alloc] init];
    content.view = _contentRoot;
    NSViewController *sidebar = [[NSViewController alloc] init];
    sidebar.view = [self buildSidebar];

    _split = [[NSSplitViewController alloc] init];
    _sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebar];
    _sidebarItem.minimumThickness = 170;
    _sidebarItem.maximumThickness = 380;
    _sidebarItem.canCollapse = YES;
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:content];
    contentItem.minimumThickness = 520;
    [_split addSplitViewItem:_sidebarItem];
    [_split addSplitViewItem:contentItem];
    _split.splitView.autosaveName = @"PagerSidebarSplit";
    window.contentViewController = _split;
    [window setContentSize:NSMakeSize(1180, 860)];

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"PagerDocumentToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = YES;
    toolbar.autosavesConfiguration = YES;
    window.toolbar = toolbar;

    self.windowFrameAutosaveName = @"PagerDocumentWindow";
    [window center];
}

- (NSView *)buildSidebar {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    _sidebarMode = [NSSegmentedControl segmentedControlWithImages:@[
        Symbol(@"rectangle.grid.1x2", @"Thumbnails"), Symbol(@"list.bullet.indent", @"Contents"), Symbol(@"note.text", @"Notes")
    ]
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne
                                                           target:self
                                                           action:@selector(sidebarModeChanged:)];
    [_sidebarMode setToolTip:@"Thumbnails" forSegment:0];
    [_sidebarMode setToolTip:@"Table of Contents" forSegment:1];
    [_sidebarMode setToolTip:@"Notes" forSegment:2];
    _sidebarMode.segmentDistribution = NSSegmentDistributionFillEqually;
    _sidebarMode.translatesAutoresizingMaskIntoConstraints = NO;

    _thumbnailTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    [_thumbnailTable addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"page"]];
    _thumbnailTable.headerView = nil;
    _thumbnailTable.rowHeight = 196;
    _thumbnailTable.style = NSTableViewStyleSourceList;
    _thumbnailTable.dataSource = self;
    _thumbnailTable.delegate = self;
    _thumbnailTable.target = self;
    _thumbnailTable.action = @selector(thumbnailClicked:);
    _thumbnailScroll = ScrollFor(_thumbnailTable);

    _outlineView = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *outlineColumn = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    [_outlineView addTableColumn:outlineColumn];
    _outlineView.outlineTableColumn = outlineColumn;
    _outlineView.headerView = nil;
    _outlineView.style = NSTableViewStyleSourceList;
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.target = self;
    _outlineView.action = @selector(outlineClicked:);
    _outlineScroll = ScrollFor(_outlineView);

    _notesTable = [[PagerNotesTableView alloc] initWithFrame:NSZeroRect];
    [_notesTable addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"note"]];
    _notesTable.headerView = nil;
    _notesTable.rowHeight = 40;
    _notesTable.style = NSTableViewStyleSourceList;
    _notesTable.dataSource = self;
    _notesTable.delegate = self;
    _notesTable.target = self;
    _notesTable.doubleAction = @selector(noteDoubleClicked:);
    NSMenu *noteMenu = [[NSMenu alloc] initWithTitle:@""];
    [noteMenu addItemWithTitle:@"Edit Text" action:@selector(editSelectedText:) keyEquivalent:@""];
    [noteMenu addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
    _notesTable.menu = noteMenu;
    _notesScroll = ScrollFor(_notesTable);
    _emptyNotesLabel = [NSTextField labelWithString:@"No Notes\nHighlight text or draw on a page."];
    _emptyNotesLabel.alignment = NSTextAlignmentCenter;
    _emptyNotesLabel.textColor = NSColor.secondaryLabelColor;
    _emptyNotesLabel.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[_sidebarMode, _thumbnailScroll, _outlineScroll, _notesScroll, _emptyNotesLabel]) {
        [root addSubview:view];
    }
    NSLayoutGuide *safe = root.safeAreaLayoutGuide;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [_sidebarMode.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [_sidebarMode.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],
        [_sidebarMode.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [_emptyNotesLabel.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_emptyNotesLabel.centerYAnchor constraintEqualToAnchor:root.centerYAnchor],
        [_emptyNotesLabel.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-24],
    ]];
    for (NSScrollView *scroll in @[_thumbnailScroll, _outlineScroll, _notesScroll]) {
        [constraints addObjectsFromArray:@[
            [scroll.topAnchor constraintEqualToAnchor:_sidebarMode.bottomAnchor constant:8],
            [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    const NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:kSidebarModeKey];
    [self showSidebarMode:std::clamp<NSInteger>(mode, 0, 2)];
    return root;
}

- (NSView *)buildMarkupBar {
    NSMutableArray<NSImage *> *images = [NSMutableArray array];
    for (const ToolEntry &entry : kTools) {
        [images addObject:Symbol(entry.symbol, entry.label)];
    }
    _toolControl = [NSSegmentedControl segmentedControlWithImages:images
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne
                                                           target:self
                                                           action:@selector(toolSegmentChanged:)];
    _toolControl.segmentStyle = NSSegmentStyleSeparated;
    for (NSInteger index = 0; index < kToolCount; ++index) {
        NSString *tip = kTools[index].shortcut != nil
                            ? [NSString stringWithFormat:@"%@ (%@)", kTools[index].label, kTools[index].shortcut]
                            : kTools[index].label;
        [_toolControl setToolTip:tip forSegment:index];
    }
    _toolControl.selectedSegment = 0;

    _colorPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _colorPopup.bezelStyle = NSBezelStyleTexturedRounded;
    _colorPopup.target = self;
    _colorPopup.action = @selector(colorPopupChanged:);
    _colorPopup.toolTip = @"Color";
    _sizePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _sizePopup.bezelStyle = NSBezelStyleTexturedRounded;
    _sizePopup.target = self;
    _sizePopup.action = @selector(sizePopupChanged:);
    _sizePopup.toolTip = @"Line Width / Font Size";

    NSStackView *stack = [NSStackView stackViewWithViews:@[_toolControl, _colorPopup, _sizePopup]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 12;
    [stack setCustomSpacing:18 afterView:_toolControl];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *bar = [[NSView alloc] initWithFrame:NSZeroRect];
    [bar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-10],
        [stack.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [bar.heightAnchor constraintEqualToConstant:40],
    ]];
    return bar;
}

- (void)windowDidLoad {
    [super windowDidLoad];
}

- (void)setDocument:(id)document {
    [super setDocument:document];
    PagerDocument *pager = [document isKindOfClass:[PagerDocument class]] ? document : nil;
    if (pager == nil) {
        [_canvas detach];
        return;
    }
    _pagerDocument = pager;
    pager.session.setTool(pager::Tool::Scroll);
    [_canvas attachToDocument:pager];
    [_outlineView reloadData];
    [_notesTable reloadData];
    [_thumbnailTable reloadData];
    [self refreshStyleControls];
    [self refreshNotesList];
    [self updatePageLabel];
    // Fit width once the window has its final size.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateScrollInsets];
        [self zoomToFitWidth:nil];
        [self scrollToDocumentY:0];
        [self visibleBoundsChanged:nil];
        // Show the markup bar once so it is discoverable, then let it tuck away.
        [self revealMarkupBarBriefly];
    });
}

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[
        NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier, kToolbarPages,
        NSToolbarFlexibleSpaceItemIdentifier, kToolbarZoom, kToolbarShare, kToolbarSearch
    ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[
        NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier, kToolbarPages, kToolbarZoom,
        kToolbarShare, kToolbarSearch, NSToolbarFlexibleSpaceItemIdentifier, NSToolbarSpaceItemIdentifier
    ];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
        itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
    willBeInsertedIntoToolbar:(BOOL)flag {
    if ([identifier isEqualToString:kToolbarPages]) {
        NSToolbarItemGroup *group = [NSToolbarItemGroup groupWithItemIdentifier:identifier
                                                                          images:@[Symbol(@"chevron.up", @"Previous Page"),
                                                                                   Symbol(@"chevron.down", @"Next Page")]
                                                                   selectionMode:NSToolbarItemGroupSelectionModeMomentary
                                                                          labels:@[@"Previous", @"Next"]
                                                                          target:self
                                                                          action:@selector(pageGroupClicked:)];
        group.label = @"Page";
        group.toolTip = @"Previous / Next Page";
        return group;
    }
    if ([identifier isEqualToString:kToolbarZoom]) {
        NSToolbarItemGroup *group = [NSToolbarItemGroup groupWithItemIdentifier:identifier
                                                                          images:@[Symbol(@"minus.magnifyingglass", @"Zoom Out"),
                                                                                   Symbol(@"plus.magnifyingglass", @"Zoom In")]
                                                                   selectionMode:NSToolbarItemGroupSelectionModeMomentary
                                                                          labels:@[@"Zoom Out", @"Zoom In"]
                                                                          target:self
                                                                          action:@selector(zoomGroupClicked:)];
        group.label = @"Zoom";
        return group;
    }
    if ([identifier isEqualToString:kToolbarShare]) {
        NSSharingServicePickerToolbarItem *share = [[NSSharingServicePickerToolbarItem alloc] initWithItemIdentifier:identifier];
        share.delegate = self;
        share.label = @"Share";
        share.toolTip = @"Share the annotated PDF";
        return share;
    }
    if ([identifier isEqualToString:kToolbarSearch]) {
        _searchItem = [[NSSearchToolbarItem alloc] initWithItemIdentifier:identifier];
        _searchItem.searchField.placeholderString = @"Search";
        _searchItem.searchField.sendsWholeSearchString = YES;
        _searchItem.searchField.target = self;
        _searchItem.searchField.action = @selector(searchFieldSubmitted:);
        _searchItem.searchField.delegate = self;
        _searchItem.label = @"Search";
        return _searchItem;
    }
    return nil;
}

- (NSArray *)itemsForSharingServicePickerToolbarItem:(NSSharingServicePickerToolbarItem *)item {
    PagerDocument *document = _pagerDocument;
    if (document == nil) {
        return @[];
    }
    __weak PagerCanvasView *canvas = _canvas;
    NSString *name = document.displayName.stringByDeletingPathExtension ?: @"Document";
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[name stringByAppendingString:@" (Annotated).pdf"]]];
    NSItemProvider *provider = [[NSItemProvider alloc] init];
    provider.suggestedName = url.lastPathComponent;
    // AppKit calls this on every toolbar validation pass, so nothing here may disturb editing;
    // the flattened copy is rendered only once a service actually asks for it.
    [provider registerFileRepresentationForContentType:UTTypePDF
                                           visibility:NSItemProviderRepresentationVisibilityAll
                                          openInPlace:NO
                                          loadHandler:^NSProgress *(void (^completion)(NSURL *, BOOL, NSError *)) {
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                  [canvas endTextEditing];
                                                  [document exportAnnotatedPDFToURL:url
                                                                         completion:^(BOOL success, NSError *error) {
                                                                             completion(success ? url : nil, NO, error);
                                                                         }];
                                              });
                                              return nil;
                                          }];
    return @[provider];
}

#pragma mark - Markup bar and styles

- (void)selectTool:(pager::Tool)tool {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    [_canvas endTextEditing];
    [_canvas.controller cancelGesture];
    session->setTool(tool);
    if (tool != pager::Tool::Scroll && tool != pager::Tool::SelectNote) {
        session->setSelectedNote({});
    }
    _toolControl.selectedSegment = SegmentForTool(tool);
    // Tools picked from the keyboard or menu flash the bar so the change is visible.
    [self revealMarkupBarBriefly];
    [_canvas.controller contentDidChange];
    [_canvas.window invalidateCursorRectsForView:_canvas];
    [self refreshStyleControls];
}

- (void)toolSegmentChanged:(NSSegmentedControl *)sender {
    const NSInteger index = sender.selectedSegment;
    if (index >= 0 && index < kToolCount) {
        [self selectTool:kTools[index].tool];
    }
}

- (void)selectToolFromMenu:(NSMenuItem *)sender {
    [self selectTool:static_cast<pager::Tool>(sender.tag)];
}

- (void)styleTool:(pager::Tool *)tool color:(pager::Color *)color size:(float *)size selected:(BOOL *)selected {
    pager::DocumentSession *session = [self session];
    pager::Tool styleTool = session == nullptr ? pager::Tool::Scroll : session->tool();
    const pager::Annotation *note = session == nullptr ? nullptr : session->selectedAnnotation();
    if (note != nullptr) {
        styleTool = pager::ToolForAnnotation(*note);
    }
    const pager::ToolStyle style = session == nullptr ? pager::DefaultStyleForTool(styleTool) : session->toolStyle(styleTool);
    *tool = styleTool;
    *color = note != nullptr ? note->color : style.color;
    *size = note != nullptr ? (note->kind == pager::AnnotationKind::FreeText ? note->fontSize : note->lineWidth)
                            : (styleTool == pager::Tool::FreeText ? style.fontSize : style.lineWidth);
    *selected = note != nullptr;
}

- (void)refreshStyleControls {
    pager::Tool tool = pager::Tool::Scroll;
    pager::Color current{};
    float size = 0;
    BOOL selected = NO;
    [self styleTool:&tool color:&current size:&size selected:&selected];
    const BOOL styled = pager::ToolHasStyle(tool);
    [_colorPopup removeAllItems];
    [_sizePopup removeAllItems];
    _colorPopup.enabled = styled;
    if (styled) {
        const std::vector<pager::Color> colors = pager::PaletteColors(tool);
        NSInteger match = -1;
        for (std::size_t index = 0; index < colors.size(); ++index) {
            // Titles must be unique within a popup; names repeat only in custom palettes.
            NSString *name = ColorName(colors[index]);
            if ([_colorPopup itemWithTitle:name] != nil) {
                name = [NSString stringWithFormat:@"%@ %zu", name, index + 1];
            }
            [_colorPopup addItemWithTitle:name];
            NSMenuItem *item = _colorPopup.lastItem;
            item.image = Swatch(colors[index], 14);
            item.representedObject = @[@(colors[index].r), @(colors[index].g), @(colors[index].b), @(colors[index].a)];
            if (match < 0 && pager::SameHue(colors[index], current)) {
                match = static_cast<NSInteger>(index);
            }
        }
        if (match < 0) {
            [_colorPopup insertItemWithTitle:@"Custom" atIndex:0];
            NSMenuItem *item = [_colorPopup itemAtIndex:0];
            item.image = Swatch(current, 14);
            item.representedObject = @[@(current.r), @(current.g), @(current.b), @(current.a)];
            match = 0;
        }
        [_colorPopup.menu addItem:NSMenuItem.separatorItem];
        [_colorPopup addItemWithTitle:@"Other Color…"];
        _colorPopup.lastItem.tag = -1;
        [_colorPopup selectItemAtIndex:match];
    } else {
        [_colorPopup addItemWithTitle:@"Color"];
        _colorPopup.lastItem.image = Swatch(pager::Color{0.6f, 0.6f, 0.6f, 0.5f}, 14);
    }
    const std::vector<float> sizes = styled ? pager::PaletteSizes(tool) : std::vector<float>{};
    _sizePopup.enabled = !sizes.empty();
    if (sizes.empty()) {
        [_sizePopup addItemWithTitle:@"Size"];
    }
    NSInteger sizeMatch = -1;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
        NSString *title = tool == pager::Tool::FreeText ? [NSString stringWithFormat:@"%.0f pt", sizes[index]]
                                                        : @[@"Thin", @"Medium", @"Thick", @"Heavy"][std::min<std::size_t>(index, 3)];
        [_sizePopup addItemWithTitle:title];
        _sizePopup.lastItem.representedObject = @(sizes[index]);
        if (std::fabs(sizes[index] - size) < 0.26f) {
            sizeMatch = static_cast<NSInteger>(index);
        }
    }
    if (!sizes.empty()) {
        [_sizePopup selectItemAtIndex:std::max<NSInteger>(0, sizeMatch)];
    }
}

- (void)applyStyleColor:(pager::Color)color {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    pager::Tool tool = pager::Tool::Scroll;
    pager::Color current{};
    float size = 0;
    BOOL selected = NO;
    [self styleTool:&tool color:&current size:&size selected:&selected];
    if (selected) {
        [_canvas.controller applyColorToSelection:color];
    }
    pager::ToolStyle style = session->toolStyle(tool);
    style.color = color;
    session->setToolStyle(tool, style);
    [_canvas.controller contentDidChange];
    [_canvas.controller updateSelectionLayers];
    [self refreshStyleControls];
}

- (void)colorPopupChanged:(NSPopUpButton *)sender {
    NSMenuItem *item = sender.selectedItem;
    if (item.tag == -1) {
        [self showColorPanel:sender];
        [self refreshStyleControls];
        return;
    }
    NSArray<NSNumber *> *rgba = item.representedObject;
    if (rgba.count == 4) {
        [self applyStyleColor:pager::Color{rgba[0].floatValue, rgba[1].floatValue, rgba[2].floatValue, rgba[3].floatValue}];
    }
}

- (void)showColorPanel:(id)sender {
    pager::Tool tool = pager::Tool::Scroll;
    pager::Color current{};
    float size = 0;
    BOOL selected = NO;
    [self styleTool:&tool color:&current size:&size selected:&selected];
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.showsAlpha = YES;
    panel.color = [NSColor colorWithSRGBRed:current.r green:current.g blue:current.b alpha:current.a == 0 ? 1 : current.a];
    [panel setTarget:self];
    [panel setAction:@selector(colorPanelChanged:)];
    [panel orderFront:self];
}

- (void)colorPanelChanged:(NSColorPanel *)panel {
    NSColor *color = [panel.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (color == nil) {
        return;
    }
    [self applyStyleColor:pager::Color{static_cast<float>(color.redComponent), static_cast<float>(color.greenComponent),
                                       static_cast<float>(color.blueComponent), static_cast<float>(color.alphaComponent)}];
}

- (void)sizePopupChanged:(NSPopUpButton *)sender {
    pager::DocumentSession *session = [self session];
    NSNumber *value = sender.selectedItem.representedObject;
    if (session == nullptr || value == nil) {
        return;
    }
    pager::Tool tool = pager::Tool::Scroll;
    pager::Color current{};
    float size = 0;
    BOOL selected = NO;
    [self styleTool:&tool color:&current size:&size selected:&selected];
    if (selected) {
        [_canvas.controller applySizeToSelection:value.floatValue];
    }
    pager::ToolStyle style = session->toolStyle(tool);
    if (tool == pager::Tool::FreeText) {
        style.fontSize = value.floatValue;
    } else {
        style.lineWidth = value.floatValue;
    }
    session->setToolStyle(tool, style);
    [_canvas.controller contentDidChange];
    [self refreshStyleControls];
}

#pragma mark - Auto-hiding markup bar

// Pointer region that summons the bar: the strip under the toolbar around the bar, a little
// wider and deeper than the bar itself (content-root coordinates, y up).
- (NSRect)markupRevealZone {
    NSRect zone = NSInsetRect(_markupPalette.frame, -80, 0);
    const CGFloat below = 56;
    zone.origin.y -= below;
    zone.size.height = NSMaxY(_contentRoot.bounds) - zone.origin.y;
    return zone;
}

- (void)setMarkupBarVisible:(BOOL)visible {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideMarkupBar) object:nil];
    if (visible == _markupVisible) {
        return;
    }
    _markupVisible = visible;
    if (visible) {
        _markupPalette.alphaValue = 0;
        _markupPalette.hidden = NO;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = visible ? 0.18 : 0.3;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self->_markupPalette.animator.alphaValue = visible ? 1 : 0;
    }
        completionHandler:^{
            // A transparent view still takes clicks; hide it once the fade-out lands. The
            // state may have flipped back mid-fade.
            if (!self->_markupVisible) {
                self->_markupPalette.hidden = YES;
            }
        }];
}

- (void)hideMarkupBar {
    // The pointer may have come back while a popup menu from the bar was open (no move
    // events arrive during menu tracking), so ask where it is now.
    const NSPoint mouse = [_contentRoot convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    if (self.window.isKeyWindow && NSPointInRect(mouse, [self markupRevealZone])) {
        return;
    }
    [self setMarkupBarVisible:NO];
}

- (void)scheduleMarkupHide:(NSTimeInterval)delay {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideMarkupBar) object:nil];
    if (_markupVisible) {
        [self performSelector:@selector(hideMarkupBar) withObject:nil afterDelay:delay];
    }
}

- (void)revealMarkupBarBriefly {
    if (self.window == nil) {
        return;
    }
    [self setMarkupBarVisible:YES];
    const NSPoint mouse = [_contentRoot convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    if (!NSPointInRect(mouse, [self markupRevealZone])) {
        [self scheduleMarkupHide:1.6];
    }
}

- (void)trackMarkupPointer:(NSEvent *)event {
    const NSPoint point = [_contentRoot convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, [self markupRevealZone])) {
        [self setMarkupBarVisible:YES];
    } else {
        [self scheduleMarkupHide:0.5];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    [self trackMarkupPointer:event];
}

- (void)mouseEntered:(NSEvent *)event {
    [self trackMarkupPointer:event];
}

- (void)mouseExited:(NSEvent *)event {
    [self scheduleMarkupHide:0.5];
}

// Pages start below the toolbar and scroll underneath it; the markup bar floats over them.
- (void)updateScrollInsets {
    const CGFloat top = _contentRoot.safeAreaInsets.top;
    if (std::fabs(_scrollView.contentInsets.top - top) <= 0.5) {
        return;
    }
    // Content stays put when the inset changes; it only moves when the old scroll position
    // falls outside the new inset range.
    _scrollView.contentInsets = NSEdgeInsetsMake(top, 0, 0, 0);
    NSClipView *clip = _scrollView.contentView;
    const NSRect constrained = [clip constrainBoundsRect:clip.bounds];
    if (!NSEqualPoints(constrained.origin, clip.bounds.origin)) {
        [clip scrollToPoint:constrained.origin];
        [_scrollView reflectScrolledClipView:clip];
    }
}

- (void)highlightSelection:(id)sender {
    [_canvas.controller applyMarkupKind:pager::AnnotationKind::Highlight];
}

- (void)underlineSelection:(id)sender {
    [_canvas.controller applyMarkupKind:pager::AnnotationKind::Underline];
}

- (void)strikeSelection:(id)sender {
    [_canvas.controller applyMarkupKind:pager::AnnotationKind::StrikeOut];
}

#pragma mark - Notes, undo, delete

- (void)undoNotes:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session == nullptr || !session->notes().canUndo()) {
        return;
    }
    [_canvas endTextEditing];
    session->notes().undo();
    session->sanitizeSelection();
    [_pagerDocument saveNotes];
    [_canvas.controller contentDidChange];
    [self canvasViewNotesChanged:_canvas];
}

- (void)redoNotes:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session == nullptr || !session->notes().canRedo()) {
        return;
    }
    [_canvas endTextEditing];
    session->notes().redo();
    session->sanitizeSelection();
    [_pagerDocument saveNotes];
    [_canvas.controller contentDidChange];
    [self canvasViewNotesChanged:_canvas];
}

- (BOOL)canUndoNotes:(BOOL)undo {
    pager::DocumentSession *session = [self session];
    return session != nullptr && (undo ? session->notes().canUndo() : session->notes().canRedo());
}

- (void)delete:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    if (self.window.firstResponder == _notesTable && _notesTable.selectedRow >= 0 &&
        _notesTable.selectedRow < static_cast<NSInteger>(session->notes().annotations().size())) {
        session->setSelectedNote(session->notes().annotations()[static_cast<std::size_t>(_notesTable.selectedRow)].id);
    }
    [_canvas.controller deleteSelectedNote];
}

- (void)editSelectedText:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    const NSInteger row = _notesTable.clickedRow >= 0 ? _notesTable.clickedRow : _notesTable.selectedRow;
    if (sender != nil && row >= 0 && row < static_cast<NSInteger>(session->notes().annotations().size())) {
        const pager::Annotation &note = session->notes().annotations()[static_cast<std::size_t>(row)];
        session->setSelectedNote(note.id);
        [self revealNote:note];
    }
    [self.window makeFirstResponder:_canvas];
    [_canvas editSelectedNote];
}

- (void)copy:(id)sender {
    [_canvas tryToPerform:@selector(copy:) with:sender];
}

- (void)searchSelectionOnGoogle:(id)sender {
    [_canvas tryToPerform:@selector(searchSelectionOnGoogle:) with:sender];
}

#pragma mark - PagerCanvasViewDelegate

- (void)canvasViewNotesChanged:(PagerCanvasView *)canvas {
    [self refreshNotesList];
    [self refreshThumbnailsForChangedPages];
    [self refreshStyleControls];
}

- (void)canvasViewSelectionChanged:(PagerCanvasView *)canvas {
    [self syncNotesSelection];
    [self refreshStyleControls];
}

- (void)canvasView:(PagerCanvasView *)canvas openLink:(const pager::LinkHit &)link {
    if (link.hasDestination) {
        [self scrollToPage:link.pageIndex userPoint:link.point.x y:link.point.y];
    } else if (!link.url.empty()) {
        NSURL *url = [NSURL URLWithString:@(link.url.c_str()) ?: @""];
        if (url != nil) {
            [NSWorkspace.sharedWorkspace openURL:url];
        }
    }
}

- (void)canvasView:(PagerCanvasView *)canvas smartMagnifyAt:(NSPoint)documentPoint {
    const CGFloat fit = [self fitWidthMagnification];
    const CGFloat target = _scrollView.magnification < fit * 1.15 ? std::min<CGFloat>(fit * 2, 8) : fit;
    _fitsWidth = target == fit;
    [_scrollView.animator setMagnification:target centeredAtPoint:documentPoint];
}

- (void)canvasView:(PagerCanvasView *)canvas selectTool:(pager::Tool)tool {
    [self selectTool:tool];
}

#pragma mark - Viewport, zoom and pages

- (void)liveMagnifyStarted:(NSNotification *)notification {
    _magnifying = YES;
    [_canvas endTextEditing];
}

- (void)liveMagnifyEnded:(NSNotification *)notification {
    _magnifying = NO;
    _fitsWidth = std::fabs(_scrollView.magnification - [self fitWidthMagnification]) < 1e-3;
    [_canvas visibleRectDidChange];
    [self updatePageLabel];
}

- (void)visibleBoundsChanged:(NSNotification *)notification {
    if (_magnifying) {
        [_canvas visibleRectDidChangeWhileZooming];
        return;
    }
    [_canvas visibleRectDidChange];
    [self updatePageLabel];
    if (_fullScreen && notification != nil) {
        [self showPageHUD];
    }
}

// Window resized (including entering or leaving full screen): a fit-width view stays fitted.
- (void)scrollFrameChanged:(NSNotification *)notification {
    if (_fitsWidth && !_magnifying) {
        const CGFloat fit = [self fitWidthMagnification];
        if (std::fabs(_scrollView.magnification - fit) > 1e-3) {
            [self setMagnificationKeepingTop:fit];
        }
    }
    [self visibleBoundsChanged:notification];
}

#pragma mark - Full screen

- (NSApplicationPresentationOptions)window:(NSWindow *)window
      willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions {
    // Like Preview: the toolbar slides away with the menu bar and comes back on hover.
    return proposedOptions | NSApplicationPresentationFullScreen | NSApplicationPresentationAutoHideMenuBar |
           NSApplicationPresentationAutoHideToolbar;
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    _fullScreen = YES;
    [_canvas endTextEditing];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [self updateScrollInsets];
    [self showPageHUD];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    _fullScreen = NO;
    [_canvas endTextEditing];
    [self hidePageHUD];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    [self updateScrollInsets];
}

// Full screen hides the title bar and its page subtitle; a floating indicator stands in
// while the reader moves through the document.
- (void)showPageHUD {
    if (!_fullScreen || _pageHUDLabel.stringValue.length == 0) {
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hidePageHUD) object:nil];
    _pageHUD.hidden = NO;
    if (_pageHUD.alphaValue < 1) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.15;
            self->_pageHUD.animator.alphaValue = 1;
        }];
    }
    [self performSelector:@selector(hidePageHUD) withObject:nil afterDelay:1.4];
}

- (void)hidePageHUD {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hidePageHUD) object:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.35;
        self->_pageHUD.animator.alphaValue = 0;
    }
        completionHandler:^{
            // A transparent view still takes clicks; hide it so the page underneath gets them.
            if (self->_pageHUD.alphaValue < 0.01) {
                self->_pageHUD.hidden = YES;
            }
        }];
}

- (CGFloat)fitWidthMagnification {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return 1;
    }
    const pager::Size content = session->viewport().layout().contentSize();
    const CGFloat width = _scrollView.contentView.frame.size.width;
    return content.width > 1 ? std::clamp<CGFloat>(width / content.width, 0.25, 8) : 1;
}

- (NSPoint)visibleCenter {
    const NSRect visible = _canvas.visibleRect;
    return NSMakePoint(NSMidX(visible), NSMidY(visible));
}

- (void)setMagnificationKeepingTop:(CGFloat)magnification {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    const NSRect visible = _canvas.visibleRect;
    [_scrollView setMagnification:magnification centeredAtPoint:NSMakePoint(NSMidX(visible), NSMinY(visible))];
    const NSRect after = _canvas.visibleRect;
    [_canvas scrollPoint:NSMakePoint(after.origin.x, NSMinY(visible))];
}

- (void)zoomIn:(id)sender {
    _fitsWidth = NO;
    [_scrollView.animator setMagnification:std::min<CGFloat>(8, _scrollView.magnification * 1.25) centeredAtPoint:[self visibleCenter]];
}

- (void)zoomOut:(id)sender {
    _fitsWidth = NO;
    [_scrollView.animator setMagnification:std::max<CGFloat>(0.25, _scrollView.magnification / 1.25) centeredAtPoint:[self visibleCenter]];
}

- (void)zoomImageToActualSize:(id)sender {
    _fitsWidth = NO;
    [self setMagnificationKeepingTop:1];
}

- (void)zoomToFitWidth:(id)sender {
    _fitsWidth = YES;
    [self setMagnificationKeepingTop:[self fitWidthMagnification]];
}

- (void)zoomToFitPage:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    _fitsWidth = NO;
    const int page = std::max(0, [self currentPageIndex]);
    const pager::Rect frame = session->viewport().layout().pageFrame(page);
    const NSSize view = _scrollView.contentView.frame.size;
    const CGFloat insetTop = _scrollView.contentInsets.top;
    const CGFloat magnification = std::clamp<CGFloat>(
        std::min((view.width - 24) / std::max(1.0, frame.width), (view.height - insetTop - 24) / std::max(1.0, frame.height)), 0.25, 8);
    [_scrollView setMagnification:magnification];
    [self scrollToDocumentY:frame.y - pager::Layout::kPageGap];
}

- (void)zoomGroupClicked:(NSToolbarItemGroup *)group {
    if (group.selectedIndex == 0) {
        [self zoomOut:group];
    } else {
        [self zoomIn:group];
    }
}

- (int)currentPageIndex {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return -1;
    }
    const NSRect visible = _canvas.visibleRect;
    const pager::Layout &layout = session->viewport().layout();
    int best = -1;
    double bestVisible = 0;
    for (const int index : layout.pagesIntersecting(pager::Rect{visible.origin.x, visible.origin.y, visible.size.width, visible.size.height})) {
        const pager::Rect frame = layout.pageFrame(index);
        const double overlap = std::min(frame.y + frame.height, NSMaxY(visible)) - std::max(frame.y, NSMinY(visible));
        if (overlap > bestVisible) {
            bestVisible = overlap;
            best = index;
        }
    }
    return best;
}

- (void)updatePageLabel {
    pager::DocumentSession *session = [self session];
    const int count = session == nullptr ? 0 : static_cast<int>(session->viewport().pages().size());
    const int page = [self currentPageIndex];
    NSMutableString *subtitle = [NSMutableString string];
    if (count > 0) {
        [subtitle appendFormat:@"Page %d of %d", std::max(1, page + 1), count];
    }
    if (session != nullptr && _searching) {
        const int hits = static_cast<int>(session->searchHits().size());
        if (hits == 0) {
            [subtitle appendString:@"  ·  No matches"];
        } else {
            [subtitle appendFormat:@"  ·  Match %d of %d", session->searchIndex() + 1, hits];
        }
    }
    self.window.subtitle = subtitle;
    _pageHUDLabel.stringValue = count > 0 ? [NSString stringWithFormat:@"%d of %d", std::max(1, page + 1), count] : @"";
    if (page != _currentPage) {
        _currentPage = page;
        if (page >= 0 && _thumbnailTable.selectedRow != page && !_syncingSelection) {
            _syncingSelection = YES;
            [_thumbnailTable selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(page)] byExtendingSelection:NO];
            [_thumbnailTable scrollRowToVisible:page];
            _syncingSelection = NO;
        }
    }
}

- (void)scrollToDocumentY:(double)y {
    NSClipView *clip = _scrollView.contentView;
    const CGFloat insetTop = _scrollView.contentInsets.top / std::max<CGFloat>(0.05, _scrollView.magnification);
    // Through the clip view so the result may sit inside the top inset (under the toolbar),
    // which -scrollPoint: clamps away.
    const NSRect target = [clip constrainBoundsRect:NSMakeRect(clip.bounds.origin.x, y - insetTop, clip.bounds.size.width,
                                                                clip.bounds.size.height)];
    [clip scrollToPoint:target.origin];
    [_scrollView reflectScrolledClipView:clip];
    [self updatePageLabel];
}

- (void)scrollToPage:(int)page userPoint:(double)x y:(double)y {
    pager::DocumentSession *session = [self session];
    const pager::PageGeometry *geometry = session == nullptr ? nullptr : session->viewport().geometry(page);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point point = session->viewport().layout().pageViewToDocument(page, pager::UserToPageView(*geometry, pager::Point{x, y}));
    [self scrollToDocumentY:point.y - 40];
}

- (void)goToPageIndex:(int)page {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    const int count = static_cast<int>(session->viewport().pages().size());
    if (count == 0) {
        return;
    }
    page = std::clamp(page, 0, count - 1);
    [self scrollToDocumentY:session->viewport().layout().pageFrame(page).y - pager::Layout::kPageGap * 0.5];
}

- (void)previousPage:(id)sender {
    [self goToPageIndex:[self currentPageIndex] - 1];
}

- (void)nextPage:(id)sender {
    [self goToPageIndex:[self currentPageIndex] + 1];
}

- (void)firstPage:(id)sender {
    [self goToPageIndex:0];
}

- (void)lastPage:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session != nullptr) {
        [self goToPageIndex:static_cast<int>(session->viewport().pages().size()) - 1];
    }
}

- (void)pageGroupClicked:(NSToolbarItemGroup *)group {
    if (group.selectedIndex == 0) {
        [self previousPage:group];
    } else {
        [self nextPage:group];
    }
}

- (void)goToPage:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Go to Page";
    alert.informativeText = [NSString stringWithFormat:@"Enter a page number from 1 to %zu.", session->viewport().pages().size()];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)];
    field.stringValue = [NSString stringWithFormat:@"%d", std::max(1, [self currentPageIndex] + 1)];
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Go"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                      if (response == NSAlertFirstButtonReturn) {
                          [self goToPageIndex:field.intValue - 1];
                      }
                  }];
}

#pragma mark - Search

- (void)performFindPanelAction:(id)sender {
    [self focusSearch:sender];
}

- (void)focusSearch:(id)sender {
    if (_searchItem != nil) {
        [_searchItem beginSearchInteraction];
    }
}

- (void)runSearch:(NSString *)query {
    PagerDocument *document = _pagerDocument;
    if (document == nil) {
        return;
    }
    _lastQuery = [query copy];
    if (query.length == 0) {
        [document.source cancelSearch];
        document.session.clearSearch();
        _searching = NO;
        [_canvas.controller contentDidChange];
        [self updatePageLabel];
        return;
    }
    _searching = YES;
    __weak PagerWindowController *weakSelf = self;
    [document.source findString:query
                     completion:^(std::vector<pager::TextSelection> hits) {
                         PagerWindowController *strongSelf = weakSelf;
                         if (strongSelf == nil || strongSelf->_pagerDocument != document) {
                             return;
                         }
                         document.session.setSearchHits(std::move(hits));
                         [strongSelf revealCurrentHit];
                     }];
}

- (void)revealCurrentHit {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    if (const pager::TextSelection *hit = session->currentSearchHit(); hit != nullptr && !hit->quads.empty()) {
        [self scrollToPage:hit->quads.front().pageIndex userPoint:hit->quads.front().quad.v[2].x y:hit->quads.front().quad.v[2].y];
    }
    [_canvas.controller contentDidChange];
    [self updatePageLabel];
}

- (void)searchFieldSubmitted:(NSSearchField *)field {
    NSString *query = field.stringValue ?: @"";
    pager::DocumentSession *session = [self session];
    if (session != nullptr && [query isEqualToString:_lastQuery] && !session->searchHits().empty()) {
        const BOOL backwards = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
        [self stepSearch:backwards ? -1 : 1];
        return;
    }
    [self runSearch:query];
}

- (void)searchFieldDidEndSearching:(NSSearchField *)sender {
    [self runSearch:@""];
}

- (void)stepSearch:(int)delta {
    pager::DocumentSession *session = [self session];
    if (session != nullptr && session->advanceSearch(delta)) {
        [self revealCurrentHit];
    }
}

- (void)findNext:(id)sender {
    [self stepSearch:1];
}

- (void)findPrevious:(id)sender {
    [self stepSearch:-1];
}

- (void)useSelectionForFind:(id)sender {
    pager::DocumentSession *session = [self session];
    if (session == nullptr || session->selection().text.empty()) {
        return;
    }
    NSString *text = @(session->selection().text.c_str()) ?: @"";
    _searchItem.searchField.stringValue = text;
    [self runSearch:text];
}

#pragma mark - File actions

- (void)exportAnnotatedPDF:(id)sender {
    PagerDocument *document = _pagerDocument;
    if (document == nil) {
        return;
    }
    [_canvas endTextEditing];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePDF];
    panel.nameFieldStringValue =
        [(document.displayName.stringByDeletingPathExtension ?: @"Document") stringByAppendingString:@" (Annotated).pdf"];
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
                      if (response != NSModalResponseOK || panel.URL == nil) {
                          return;
                      }
                      [document exportAnnotatedPDFToURL:panel.URL
                                             completion:^(BOOL success, NSError *error) {
                                                 if (!success) {
                                                     [self presentError:error ?: [NSError errorWithDomain:@"PagerPDF" code:4 userInfo:nil]
                                                         modalForWindow:self.window
                                                               delegate:nil
                                                     didPresentSelector:nil
                                                            contextInfo:nullptr];
                                                 }
                                             }];
                  }];
}

- (void)printDocument:(id)sender {
    PagerDocument *document = _pagerDocument;
    if (document == nil) {
        return;
    }
    [_canvas endTextEditing];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                                                    [NSString stringWithFormat:@"pager-print-%@.pdf", NSUUID.UUID.UUIDString]]];
    [document exportAnnotatedPDFToURL:url
                           completion:^(BOOL success, NSError *error) {
                               PDFDocument *flattened = success ? [[PDFDocument alloc] initWithURL:url] : nil;
                               NSPrintOperation *operation = [flattened printOperationForPrintInfo:document.printInfo
                                                                                       scalingMode:kPDFPrintPageScaleToFit
                                                                                        autoRotate:YES];
                               if (operation == nil) {
                                   NSBeep();
                                   return;
                               }
                               operation.jobTitle = document.displayName;
                               [operation runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:nullptr];
                           }];
}

#pragma mark - Sidebar

- (void)showSidebarMode:(NSInteger)mode {
    _sidebarMode.selectedSegment = mode;
    _thumbnailScroll.hidden = mode != kSidebarThumbnails;
    _outlineScroll.hidden = mode != kSidebarContents;
    _notesScroll.hidden = mode != kSidebarNotes;
    pager::DocumentSession *session = [self session];
    _emptyNotesLabel.hidden = mode != kSidebarNotes || (session != nullptr && !session->notes().annotations().empty());
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kSidebarModeKey];
}

- (void)sidebarModeChanged:(NSSegmentedControl *)sender {
    [self showSidebarMode:sender.selectedSegment];
}

- (void)showSidebarModeFromMenu:(NSMenuItem *)sender {
    if (_sidebarItem.collapsed) {
        _sidebarItem.animator.collapsed = NO;
    }
    [self showSidebarMode:sender.tag];
}

- (void)refreshNotesList {
    pager::DocumentSession *session = [self session];
    const std::uint64_t revision = session == nullptr ? 0 : session->notes().revision();
    if (revision != _notesRevisionShown) {
        _notesRevisionShown = revision;
        _syncingSelection = YES;
        [_notesTable reloadData];
        _syncingSelection = NO;
    }
    _emptyNotesLabel.hidden = _notesScroll.hidden || (session != nullptr && !session->notes().annotations().empty());
    [self syncNotesSelection];
}

- (void)syncNotesSelection {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    _syncingSelection = YES;
    const auto &notes = session->notes().annotations();
    NSInteger row = -1;
    for (std::size_t index = 0; index < notes.size(); ++index) {
        if (notes[index].id == session->selectedNote()) {
            row = static_cast<NSInteger>(index);
            break;
        }
    }
    if (row >= 0) {
        [_notesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)] byExtendingSelection:NO];
        [_notesTable scrollRowToVisible:row];
    } else {
        [_notesTable deselectAll:nil];
    }
    _syncingSelection = NO;
}

- (void)revealNote:(const pager::Annotation &)note {
    const NSRect rect = NSRectFromCGRect([_canvas.controller documentRectForNote:note]);
    if (!NSContainsRect(_canvas.visibleRect, rect)) {
        [self scrollToDocumentY:NSMinY(rect) - 60];
    }
    [_canvas.controller updateChrome];
    [self refreshStyleControls];
}

- (void)noteDoubleClicked:(id)sender {
    [self editSelectedText:sender];
}

- (void)thumbnailClicked:(id)sender {
    if (_thumbnailTable.clickedRow >= 0) {
        [self goToPageIndex:static_cast<int>(_thumbnailTable.clickedRow)];
    }
}

- (void)outlineClicked:(id)sender {
    PagerOutlineNode *node = [_outlineView itemAtRow:_outlineView.clickedRow];
    if (node != nil && node.page >= 0) {
        [self scrollToPage:static_cast<int>(node.page) userPoint:node.x y:node.y];
    }
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (item == nil) {
        return static_cast<NSInteger>(_pagerDocument.outline.count);
    }
    return static_cast<NSInteger>(((PagerOutlineNode *)item).children.count);
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    NSArray<PagerOutlineNode *> *children = item == nil ? _pagerDocument.outline : ((PagerOutlineNode *)item).children;
    return children[static_cast<NSUInteger>(index)];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return ((PagerOutlineNode *)item).children.count > 0;
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)column item:(id)item {
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"outline" owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"outline";
        NSTextField *text = [NSTextField labelWithString:@""];
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *page = [NSTextField labelWithString:@""];
        page.textColor = NSColor.secondaryLabelColor;
        page.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        page.translatesAutoresizingMaskIntoConstraints = NO;
        page.tag = 7;
        [cell addSubview:text];
        [cell addSubview:page];
        cell.textField = text;
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [page.leadingAnchor constraintGreaterThanOrEqualToAnchor:text.trailingAnchor constant:6],
            [page.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [page.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        [page setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    PagerOutlineNode *node = item;
    cell.textField.stringValue = node.title ?: @"";
    NSTextField *page = [cell viewWithTag:7];
    page.stringValue = node.page >= 0 ? [NSString stringWithFormat:@"%ld", (long)node.page + 1] : @"";
    return cell;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return 0;
    }
    if (tableView == _thumbnailTable) {
        return static_cast<NSInteger>(session->viewport().pages().size());
    }
    return static_cast<NSInteger>(session->notes().annotations().size());
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return nil;
    }
    if (tableView == _thumbnailTable) {
        return [self thumbnailCellForRow:row];
    }
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"note" owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"note";
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
        NSTextField *title = [NSTextField labelWithString:@""];
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *detail = [NSTextField labelWithString:@""];
        detail.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        detail.textColor = NSColor.secondaryLabelColor;
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        detail.tag = 7;
        [cell addSubview:icon];
        [cell addSubview:title];
        [cell addSubview:detail];
        cell.imageView = icon;
        cell.textField = title;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:20],
            [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [title.topAnchor constraintEqualToAnchor:cell.topAnchor constant:3],
            [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [detail.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:1],
        ]];
    }
    const auto &notes = session->notes().annotations();
    if (row < 0 || row >= static_cast<NSInteger>(notes.size())) {
        return cell;
    }
    const pager::Annotation &note = notes[static_cast<std::size_t>(row)];
    cell.imageView.image = Symbol(KindSymbol(note.kind), KindTitle(note.kind));
    cell.imageView.contentTintColor = [NSColor colorWithSRGBRed:note.color.r green:note.color.g blue:note.color.b alpha:1];
    NSString *contents = note.contents.empty() ? nil : [@(note.contents.c_str()) stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    cell.textField.stringValue = contents.length > 0 ? contents : KindTitle(note.kind);
    NSTextField *detail = [cell viewWithTag:7];
    detail.stringValue = [NSString stringWithFormat:@"Page %d · %@", note.pageIndex + 1, KindTitle(note.kind)];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_syncingSelection) {
        return;
    }
    pager::DocumentSession *session = [self session];
    if (session == nullptr) {
        return;
    }
    if (notification.object == _thumbnailTable) {
        if (_thumbnailTable.selectedRow >= 0 && NSApp.currentEvent.type != NSEventTypeScrollWheel) {
            if (static_cast<int>(_thumbnailTable.selectedRow) != [self currentPageIndex]) {
                [self goToPageIndex:static_cast<int>(_thumbnailTable.selectedRow)];
            }
        }
        return;
    }
    const NSInteger row = _notesTable.selectedRow;
    const auto &notes = session->notes().annotations();
    if (row < 0 || row >= static_cast<NSInteger>(notes.size())) {
        return;
    }
    const pager::Annotation note = notes[static_cast<std::size_t>(row)];
    session->setSelectedNote(note.id);
    [self revealNote:note];
}

#pragma mark - Thumbnails

- (NSView *)thumbnailCellForRow:(NSInteger)row {
    NSTableCellView *cell = [_thumbnailTable makeViewWithIdentifier:@"thumb" owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"thumb";
        NSImageView *image = [[NSImageView alloc] initWithFrame:NSZeroRect];
        image.imageScaling = NSImageScaleProportionallyUpOrDown;
        image.wantsLayer = YES;
        image.layer.shadowOpacity = 0.25f;
        image.layer.shadowRadius = 2;
        image.layer.shadowOffset = CGSizeMake(0, -1);
        image.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.alignment = NSTextAlignmentCenter;
        label.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        label.textColor = NSColor.secondaryLabelColor;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:image];
        [cell addSubview:label];
        cell.imageView = image;
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [image.topAnchor constraintEqualToAnchor:cell.topAnchor constant:8],
            [image.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
            [image.widthAnchor constraintLessThanOrEqualToAnchor:cell.widthAnchor constant:-24],
            [image.heightAnchor constraintEqualToConstant:160],
            [image.widthAnchor constraintEqualToConstant:140],
            [label.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:4],
            [label.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
        ]];
    }
    cell.textField.stringValue = [NSString stringWithFormat:@"%ld", (long)row + 1];
    cell.imageView.image = [_thumbnails objectForKey:@(row)];
    cell.imageView.tag = row;
    pager::DocumentSession *session = [self session];
    const std::uint64_t revision = session == nullptr ? 0 : session->notes().pageRevision(static_cast<int>(row));
    const auto cached = _thumbnailRevisions.find(row);
    if (cell.imageView.image == nil || cached == _thumbnailRevisions.end() || cached->second != revision) {
        [self requestThumbnailForRow:row];
    }
    return cell;
}

- (void)requestThumbnailForRow:(NSInteger)row {
    PagerDocument *document = _pagerDocument;
    pager::DocumentSession *session = [self session];
    const pager::PageGeometry *geometry = session == nullptr ? nullptr : session->viewport().geometry(static_cast<int>(row));
    if (document == nil || geometry == nullptr) {
        return;
    }
    const std::uint64_t revision = session->notes().pageRevision(static_cast<int>(row));
    _thumbnailRevisions[row] = revision;
    const pager::PageGeometry page = *geometry;
    auto notes = std::make_shared<std::vector<pager::Annotation>>();
    for (const pager::Annotation &note : session->notes().annotations()) {
        if (note.pageIndex == static_cast<int>(row)) {
            notes->push_back(note);
        }
    }
    const CGFloat pixels = 160 * std::max<CGFloat>(1, self.window.backingScaleFactor);
    __weak PagerWindowController *weakSelf = self;
    dispatch_async(_thumbnailQueue, ^{
        CGImageRef base = [document copyThumbnailForPage:row maxPixels:pixels];
        if (base == nullptr) {
            return;
        }
        const size_t width = CGImageGetWidth(base);
        const size_t height = CGImageGetHeight(base);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(nullptr, width, height, 8, 0, space,
                                                     static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipFirst) |
                                                         static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little));
        CGColorSpaceRelease(space);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), base);
        CGImageRelease(base);
        // Thumbnails show the notes too, like Preview's sidebar.
        const pager::Size displayed = pager::DisplayedSize(page);
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, width / std::max(1.0, displayed.width), -(height / std::max(1.0, displayed.height)));
        pager::InkPathCache cache;
        for (const pager::Annotation &note : *notes) {
            pager::DrawAnnotationInPage(context, page, note, {}, &cache);
        }
        CGImageRef composed = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        NSImage *image = [[NSImage alloc] initWithCGImage:composed size:NSMakeSize(width, height)];
        CGImageRelease(composed);
        dispatch_async(dispatch_get_main_queue(), ^{
            PagerWindowController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf->_thumbnails setObject:image forKey:@(row)];
            if (row < strongSelf->_thumbnailTable.numberOfRows) {
                NSTableCellView *cell = [strongSelf->_thumbnailTable viewAtColumn:0 row:row makeIfNecessary:NO];
                if (cell.imageView.tag == row) {
                    cell.imageView.image = image;
                }
            }
        });
    });
}

- (void)refreshThumbnailsForChangedPages {
    pager::DocumentSession *session = [self session];
    if (session == nullptr || _thumbnailScroll.hidden) {
        return;
    }
    const NSRange rows = [_thumbnailTable rowsInRect:_thumbnailTable.visibleRect];
    for (NSUInteger row = rows.location; row < NSMaxRange(rows); ++row) {
        const auto cached = _thumbnailRevisions.find(static_cast<NSInteger>(row));
        if (cached == _thumbnailRevisions.end() || cached->second != session->notes().pageRevision(static_cast<int>(row))) {
            [self requestThumbnailForRow:static_cast<NSInteger>(row)];
        }
    }
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    pager::DocumentSession *session = [self session];
    const SEL action = item.action;
    if (session == nullptr) {
        return NO;
    }
    if (action == @selector(selectToolFromMenu:)) {
        item.state = static_cast<pager::Tool>(item.tag) == session->tool() ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(showSidebarModeFromMenu:)) {
        item.state = !_sidebarItem.collapsed && _sidebarMode.selectedSegment == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(highlightSelection:) || action == @selector(underlineSelection:) ||
        action == @selector(strikeSelection:) || action == @selector(useSelectionForFind:)) {
        return !session->selection().quads.empty();
    }
    if (action == @selector(findNext:) || action == @selector(findPrevious:)) {
        return !session->searchHits().empty();
    }
    if (action == @selector(delete:)) {
        return session->selectedNote().value != 0 ||
               (self.window.firstResponder == _notesTable && _notesTable.selectedRow >= 0);
    }
    if (action == @selector(editSelectedText:)) {
        const pager::Annotation *note = session->selectedAnnotation();
        const NSInteger row = _notesTable.clickedRow >= 0 ? _notesTable.clickedRow : _notesTable.selectedRow;
        if (row >= 0 && row < static_cast<NSInteger>(session->notes().annotations().size())) {
            note = &session->notes().annotations()[static_cast<std::size_t>(row)];
        }
        return note != nullptr && note->kind == pager::AnnotationKind::FreeText;
    }
    if (action == @selector(copy:)) {
        const pager::Annotation *note = session->selectedAnnotation();
        return !session->selection().text.empty() || (note != nullptr && !note->contents.empty());
    }
    if (action == @selector(searchSelectionOnGoogle:)) {
        return !session->selection().text.empty();
    }
    if (action == @selector(previousPage:) || action == @selector(firstPage:)) {
        return [self currentPageIndex] > 0;
    }
    if (action == @selector(nextPage:) || action == @selector(lastPage:)) {
        return [self currentPageIndex] + 1 < static_cast<int>(session->viewport().pages().size());
    }
    if (action == @selector(zoomIn:)) {
        return _scrollView.magnification < 8 - 1e-3;
    }
    if (action == @selector(zoomOut:)) {
        return _scrollView.magnification > 0.25 + 1e-3;
    }
    return YES;
}

@end
