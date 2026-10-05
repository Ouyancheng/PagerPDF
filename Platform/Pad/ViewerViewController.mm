#import "ViewerViewController.h"

#import "OverlayRenderer.h"
#import "PadCanvasView.h"
#import "PadDocument.h"
#import "Zoom.hpp"

#include "Geometry.hpp"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <cmath>
#include <vector>

@interface PagerChromeButton : UIButton
@property(nonatomic, copy, nullable) void (^onMenuDidEnd)(void);
@end

namespace {

NSString *const kPagerSidebarVisibleKey = @"PagerSidebarVisible";
NSString *const kPagerChromeVisibleKey = @"PagerChromeVisible";
NSString *const kPagerDockEdgeKey = @"PagerDockEdge";

enum {
    kToolsetRead = 0,
    kToolsetMarkup = 1,
    kToolsetDraw = 2,
    kToolsetInsert = 3,
    kToolsetCount = 4,
};

enum {
    kDockBottom = 0,
    kDockLeading = 1,
    kDockTrailing = 2,
};

UIColor *CanvasColor(void) {
    return [UIColor colorWithWhite:pager::kCanvasGray alpha:1];
}

UILayoutGuide *CornerSafeGuide(UIView *view) {
    if (@available(iOS 26.0, *)) {
        return [view layoutGuideForLayoutRegion:[UIViewLayoutRegion safeAreaLayoutRegionWithCornerAdaptation:
                                                    UIViewLayoutRegionAdaptivityAxisHorizontal]];
    }
    return view.safeAreaLayoutGuide;
}

BOOL WindowFillsScreen(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if (scene == nil) {
        return YES;
    }
    const CGRect screen = scene.screen.bounds;
    const CGRect frame = window.frame;
    const CGFloat slop = 8;
    return frame.origin.x <= slop && frame.origin.y <= slop && frame.size.width >= screen.size.width - slop &&
           frame.size.height >= screen.size.height - slop;
}

CGFloat WindowControlLeadingExtra(UIView *view) {
    if (@available(iOS 26.0, *)) {
        UIWindow *window = view.window;
        if (window == nil) {
            return 0;
        }
        const UIEdgeInsets corner =
            [view edgeInsetsForLayoutRegion:[UIViewLayoutRegion safeAreaLayoutRegionWithCornerAdaptation:
                                                 UIViewLayoutRegionAdaptivityAxisHorizontal]];
        if (WindowFillsScreen(window)) {
            return view.safeAreaInsets.left - corner.left;
        }
        if (corner.left > view.safeAreaInsets.left + 1) {
            // Compact dots are in the corner guide; expanded red/yellow/green need ~120pt.
            return MAX(0, 120 - corner.left) + 10;
        }
    }
    return 0;
}

UIImage *Symbol(NSString *name, CGFloat pointSize) {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:name withConfiguration:config];
}

void ApplyRoundedChrome(UIView *view, CGFloat radius, BOOL capsule) {
    if (view == nil) {
        return;
    }
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
    if (@available(iOS 26.0, *)) {
        view.cornerConfiguration = capsule ? [UICornerConfiguration capsuleConfiguration]
                                           : [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:radius]];
    }
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        ApplyRoundedChrome(((UIVisualEffectView *)view).contentView, radius, capsule);
    }
}

void ApplyCapsuleChrome(UIButton *button) {
    if (button == nil) {
        return;
    }
    button.highlighted = NO;
    button.selected = NO;
    ApplyRoundedChrome(button, 18, YES);
}

UIButton *IconButton(NSString *symbol, NSString *label, NSInteger tag, id target, SEL action) {
    // Avoid UIButtonConfiguration here. A menu highlight leaves a square
    // configuration background that only clears after the next layout.
    PagerChromeButton *button = [PagerChromeButton buttonWithType:UIButtonTypeSystem];
    [button setImage:Symbol(symbol, 17) forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    button.adjustsImageWhenHighlighted = NO;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
    button.backgroundColor = UIColor.clearColor;
    if (action != nil) {
        [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }
    button.tag = tag;
    button.accessibilityLabel = label;
    ApplyCapsuleChrome(button);
    return button;
}

UIButton *ChipButton(NSString *title, NSInteger tag, id target, SEL action) {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
        NSMutableDictionary<NSAttributedStringKey, id> *next = incoming.mutableCopy ?: [NSMutableDictionary dictionary];
        next[NSFontAttributeName] = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        return next;
    };
    config.contentInsets = NSDirectionalEdgeInsetsMake(7, 12, 7, 12);
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseForegroundColor = UIColor.labelColor;
    config.titleLineBreakMode = NSLineBreakByClipping;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    button.tag = tag;
    button.accessibilityLabel = title;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

void StyleSelected(UIButton *button, BOOL selected) {
    if (button.configuration != nil) {
        UIButtonConfiguration *config = [button.configuration copy];
        config.baseForegroundColor = selected ? UIColor.whiteColor : UIColor.labelColor;
        config.background.backgroundColor = selected ? UIColor.systemBlueColor : UIColor.clearColor;
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.background.cornerRadius = 18;
        button.configuration = config;
    } else {
        button.backgroundColor = selected ? UIColor.systemBlueColor : UIColor.clearColor;
        button.tintColor = selected ? UIColor.whiteColor : UIColor.labelColor;
    }
    ApplyCapsuleChrome(button);
}

UIVisualEffect *GlassEffect(void) {
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        // Interactive glass resamples the CATiledLayer behind the pill on every
        // press. That is why the More menu felt seconds-slow.
        glass.interactive = NO;
        return glass;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
}

UIVisualEffectView *GlassPanel(CGFloat radius, BOOL capsule) {
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:GlassEffect()];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    ApplyRoundedChrome(panel, radius, capsule);
    return panel;
}

UIColor *UIColorFromPager(pager::Color color) {
    return [UIColor colorWithRed:color.r green:color.g blue:color.b alpha:std::max(0.4f, color.a == 0 ? 1 : color.a)];
}

UIImage *ColorDot(pager::Color color) {
    const CGSize size = CGSizeMake(18, 18);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColorFromPager(color) setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 16, 16)] fill];
    }];
}

NSArray<NSString *> *SizeChipLabels(const std::vector<float> &sizes, pager::Tool tool) {
    if (tool != pager::Tool::FreeText) {
        return @[ @"S", @"M", @"L" ];
    }
    NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:sizes.size()];
    for (float size : sizes) {
        [labels addObject:[NSString stringWithFormat:@"%.0f", size]];
    }
    return labels;
}

pager::Tool ToolForKind(pager::AnnotationKind kind) {
    switch (kind) {
        case pager::AnnotationKind::Highlight:
            return pager::Tool::Highlight;
        case pager::AnnotationKind::Underline:
            return pager::Tool::Underline;
        case pager::AnnotationKind::StrikeOut:
            return pager::Tool::StrikeOut;
        case pager::AnnotationKind::Circle:
            return pager::Tool::Circle;
        case pager::AnnotationKind::Line:
            return pager::Tool::Line;
        case pager::AnnotationKind::FreeText:
            return pager::Tool::FreeText;
        case pager::AnnotationKind::Ink:
            return pager::Tool::Pen;
        case pager::AnnotationKind::Square:
        default:
            return pager::Tool::Square;
    }
}

UIView *Hairline(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.55];
    return line;
}

BOOL DefaultFlag(NSString *key, BOOL fallback) {
    if (![NSUserDefaults.standardUserDefaults objectForKey:key]) {
        return fallback;
    }
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

const pager::Tool kReadTools[] = {pager::Tool::Scroll, pager::Tool::SelectText};
const pager::Tool kMarkupTools[] = {pager::Tool::Highlight, pager::Tool::Underline, pager::Tool::StrikeOut};
const pager::Tool kDrawTools[] = {pager::Tool::Pen, pager::Tool::Marker, pager::Tool::Eraser};
const pager::Tool kInsertTools[] = {pager::Tool::Square, pager::Tool::Circle, pager::Tool::Line, pager::Tool::FreeText};

const pager::Tool *ToolsForSet(NSInteger set, NSInteger *count) {
    switch (set) {
        case kToolsetMarkup:
            *count = 3;
            return kMarkupTools;
        case kToolsetDraw:
            *count = 3;
            return kDrawTools;
        case kToolsetInsert:
            *count = 4;
            return kInsertTools;
        case kToolsetRead:
        default:
            *count = 2;
            return kReadTools;
    }
}

NSInteger ToolsetForTool(pager::Tool tool) {
    switch (tool) {
        case pager::Tool::Highlight:
        case pager::Tool::Underline:
        case pager::Tool::StrikeOut:
            return kToolsetMarkup;
        case pager::Tool::Pen:
        case pager::Tool::Marker:
        case pager::Tool::Eraser:
            return kToolsetDraw;
        case pager::Tool::Square:
        case pager::Tool::Circle:
        case pager::Tool::Line:
        case pager::Tool::FreeText:
            return kToolsetInsert;
        default:
            return kToolsetRead;
    }
}

}  // namespace

@implementation PagerChromeButton

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                 previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    UIPreviewParameters *parameters = [[UIPreviewParameters alloc] init];
    parameters.backgroundColor = UIColor.clearColor;
    parameters.visiblePath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5];
    return [[UITargetedPreview alloc] initWithView:self parameters:parameters];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                  previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self contextMenuInteraction:interaction previewForHighlightingMenuWithConfiguration:configuration];
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    void (^restore)(void) = ^{
        self.highlighted = NO;
        self.selected = NO;
        ApplyCapsuleChrome(self);
        if (self.onMenuDidEnd != nil) {
            self.onMenuDidEnd();
        }
    };
    restore();
    if (animator != nil) {
        [animator addAnimations:restore];
        [animator addCompletion:restore];
    }
}

@end

@implementation ViewerViewController {
    PadDocument *_document;
    UIScrollView *_scrollView;
    PadCanvasView *_canvas;
    UITextField *_searchField;
    UILabel *_pageLabel;
    UITableView *_outlineTable;
    UITableView *_notesTable;
    UISegmentedControl *_sidebarControl;
    UIVisualEffectView *_sidebar;
    UIView *_dimmer;
    UIVisualEffectView *_navPill;
    UIVisualEffectView *_pagePill;
    UIVisualEffectView *_searchPill;
    UIVisualEffectView *_toolDock;
    UIStackView *_toolStack;
    UIStackView *_styleRow;
    UIStackView *_toolsetRow;
    UIStackView *_toolIcons;
    UIButton *_navigateButton;
    UIButton *_colorWell;
    UIButton *_sizeWell;
    UIView *_styleDivider;
    UIVisualEffectView *_sizePopup;
    UIControl *_sizePopupScrim;
    std::vector<pager::Color> _styleColors;
    std::vector<float> _styleSizes;
    NSArray<UIButton *> *_toolButtons;
    NSArray<UIButton *> *_toolsetButtons;
    UIButton *_sidebarButton;
    UIButton *_moreButton;
    UIButton *_searchToggle;
    NSLayoutConstraint *_searchCollapsedWidth;
    NSLayoutConstraint *_searchExpandedWidth;
    NSLayoutConstraint *_searchFieldMinWidth;
    NSLayoutConstraint *_dockCenterX;
    NSLayoutConstraint *_dockBottom;
    NSLayoutConstraint *_dockLeading;
    NSLayoutConstraint *_dockTrailing;
    NSLayoutConstraint *_dockCenterY;
    NSLayoutConstraint *_dockClearSidebar;
    NSLayoutConstraint *_navPillLeading;
    NSLayoutConstraint *_sidebarLeading;
    pager::Tool _tool;
    pager::Tool _previousTool;
    pager::Tool _lastDrawTool;
    pager::Tool _lastToolInSet[kToolsetCount];
    UIView *_zoomContent;
    UITapGestureRecognizer *_doubleTap;
    CGPoint _dockDragOrigin;
    BOOL _needsFitWidth;
    BOOL _sidebarVisible;
    BOOL _chromeVisible;
    BOOL _searchExpanded;
    NSInteger _activeToolset;
    NSInteger _dockEdge;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = CanvasColor();
    _tool = pager::Tool::Scroll;
    _previousTool = pager::Tool::Scroll;
    _lastDrawTool = pager::Tool::Pen;
    _lastToolInSet[kToolsetRead] = pager::Tool::Scroll;
    _lastToolInSet[kToolsetMarkup] = pager::Tool::Highlight;
    _lastToolInSet[kToolsetDraw] = pager::Tool::Pen;
    _lastToolInSet[kToolsetInsert] = pager::Tool::Square;
    _activeToolset = kToolsetDraw;
    _dockEdge = [NSUserDefaults.standardUserDefaults objectForKey:kPagerDockEdgeKey]
                    ? [NSUserDefaults.standardUserDefaults integerForKey:kPagerDockEdgeKey]
                    : kDockBottom;
    _sidebarVisible = DefaultFlag(kPagerSidebarVisibleKey, NO);
    _chromeVisible = DefaultFlag(kPagerChromeVisibleKey, YES);

    UIPencilInteraction *pencilInteraction = [[UIPencilInteraction alloc] init];
    pencilInteraction.delegate = (id<UIPencilInteractionDelegate>)self;
    [self.view addInteraction:pencilInteraction];

    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.delegate = (id<UIScrollViewDelegate>)self;
    _scrollView.backgroundColor = CanvasColor();
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.delaysContentTouches = NO;
    _scrollView.canCancelContentTouches = YES;
    _scrollView.minimumZoomScale = 0.25;
    _scrollView.maximumZoomScale = 8;
    _scrollView.bouncesZoom = YES;
    _scrollView.panGestureRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect), @(UITouchTypeIndirect)];
    _zoomContent = [[UIView alloc] initWithFrame:CGRectZero];
    _zoomContent.backgroundColor = CanvasColor();
    _canvas = [[PadCanvasView alloc] initWithFrame:CGRectZero];
    [_zoomContent addSubview:_canvas];
    [_scrollView addSubview:_zoomContent];
    _doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    _doubleTap.numberOfTapsRequired = 2;
    [_scrollView addGestureRecognizer:_doubleTap];

    self.view.backgroundColor = CanvasColor();
    _scrollView.backgroundColor = CanvasColor();

    _sidebarButton = IconButton(@"sidebar.left", @"Toggle Sidebar", 0, self, @selector(toggleSidebar:));
    _moreButton = IconButton(@"ellipsis", @"More", 0, self, nil);
    _moreButton.showsMenuAsPrimaryAction = YES;
    _moreButton.changesSelectionAsPrimaryAction = NO;
    _moreButton.menu = [self moreMenu];
    __weak ViewerViewController *weakChrome = self;
    ((PagerChromeButton *)_moreButton).onMenuDidEnd = ^{
        [weakChrome restoreChromeCorners];
    };
    UIStackView *navRow = [[UIStackView alloc] initWithArrangedSubviews:@[_sidebarButton, _moreButton]];
    navRow.axis = UILayoutConstraintAxisHorizontal;
    navRow.spacing = 2;
    navRow.alignment = UIStackViewAlignmentCenter;
    navRow.translatesAutoresizingMaskIntoConstraints = NO;
    _navPill = GlassPanel(20, YES);
    [_navPill.contentView addSubview:navRow];

    UIButton *prevPageButton = IconButton(@"chevron.left", @"Previous Page", 0, self, @selector(previousPage:));
    UIButton *nextPageButton = IconButton(@"chevron.right", @"Next Page", 0, self, @selector(nextPage:));
    _pageLabel = [[UILabel alloc] init];
    _pageLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    _pageLabel.textColor = UIColor.labelColor;
    _pageLabel.text = @"—";
    _pageLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *pageRow = [[UIStackView alloc] initWithArrangedSubviews:@[prevPageButton, _pageLabel, nextPageButton]];
    pageRow.axis = UILayoutConstraintAxisHorizontal;
    pageRow.spacing = 2;
    pageRow.alignment = UIStackViewAlignmentCenter;
    pageRow.translatesAutoresizingMaskIntoConstraints = NO;
    _pagePill = GlassPanel(20, YES);
    [_pagePill.contentView addSubview:pageRow];
    UITapGestureRecognizer *pageTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleChrome:)];
    _pagePill.userInteractionEnabled = YES;
    [_pagePill addGestureRecognizer:pageTap];

    _searchToggle = IconButton(@"magnifyingglass", @"Find", 0, self, @selector(toggleSearch:));
    [_searchToggle setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                   forAxis:UILayoutConstraintAxisHorizontal];
    [_searchToggle setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                   forAxis:UILayoutConstraintAxisVertical];
    [_searchToggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _searchField = [[UITextField alloc] init];
    _searchField.placeholder = @"Find in document";
    _searchField.borderStyle = UITextBorderStyleNone;
    _searchField.backgroundColor = UIColor.clearColor;
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.returnKeyType = UIReturnKeySearch;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.font = [UIFont systemFontOfSize:15];
    [_searchField addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [_searchField addTarget:self action:@selector(searchFieldEdited:) forControlEvents:UIControlEventEditingChanged];
    UIButton *prevHitButton = IconButton(@"chevron.up", @"Previous Hit", 0, self, @selector(previousSearchHit:));
    UIButton *nextHitButton = IconButton(@"chevron.down", @"Next Hit", 1, self, @selector(nextSearchHit:));
    [_searchField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                  forAxis:UILayoutConstraintAxisHorizontal];
    [_searchField setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    for (UIButton *hit in @[ prevHitButton, nextHitButton ]) {
        [hit setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [hit setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [hit.widthAnchor constraintEqualToAnchor:hit.heightAnchor].active = YES;
    }
    UIStackView *searchRow = [[UIStackView alloc] initWithArrangedSubviews:@[_searchToggle, _searchField, prevHitButton, nextHitButton]];
    searchRow.axis = UILayoutConstraintAxisHorizontal;
    searchRow.spacing = 4;
    searchRow.alignment = UIStackViewAlignmentCenter;
    searchRow.translatesAutoresizingMaskIntoConstraints = NO;
    _searchPill = GlassPanel(20, YES);
    [_searchPill.contentView addSubview:searchRow];
    _searchField.hidden = YES;
    prevHitButton.hidden = YES;
    nextHitButton.hidden = YES;
    prevHitButton.tag = 10;
    nextHitButton.tag = 11;

    const pager::Tool tools[] = {
        pager::Tool::Scroll,    pager::Tool::SelectNote, pager::Tool::SelectText, pager::Tool::Highlight, pager::Tool::Underline,
        pager::Tool::StrikeOut, pager::Tool::Square,     pager::Tool::Circle,     pager::Tool::Line,      pager::Tool::FreeText,
        pager::Tool::Pen,       pager::Tool::Marker,     pager::Tool::Eraser,
    };
    NSArray<NSString *> *symbols = @[
        @"cursorarrow", @"cursorarrow", @"character.cursor.ibeam", @"highlighter", @"underline", @"strikethrough", @"rectangle",
        @"circle", @"line.diagonal", @"note.text", @"pencil.tip", @"paintbrush.pointed", @"eraser"
    ];
    NSArray<NSString *> *labels = @[
        @"Cursor", @"Select Note", @"Select Text", @"Highlight", @"Underline", @"Strike Out", @"Rectangle", @"Circle", @"Line",
        @"Text Note", @"Pen", @"Marker", @"Eraser"
    ];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    _toolIcons = [[UIStackView alloc] init];
    _toolIcons.spacing = 2;
    _toolIcons.alignment = UIStackViewAlignmentCenter;
    _toolIcons.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSUInteger index = 0; index < symbols.count; ++index) {
        UIButton *button = IconButton(symbols[index], labels[index], static_cast<NSInteger>(tools[index]), self, @selector(selectTool:));
        [_toolIcons addArrangedSubview:button];
        [buttons addObject:button];
    }
    _toolButtons = buttons;

    UIButton *markupSet = ChipButton(@"Markup", kToolsetMarkup, self, @selector(selectToolset:));
    UIButton *drawSet = ChipButton(@"Draw", kToolsetDraw, self, @selector(selectToolset:));
    UIButton *insertSet = ChipButton(@"Insert", kToolsetInsert, self, @selector(selectToolset:));
    _toolsetButtons = @[markupSet, drawSet, insertSet];
    _toolsetRow = [[UIStackView alloc] initWithArrangedSubviews:_toolsetButtons];
    _toolsetRow.spacing = 2;
    _toolsetRow.alignment = UIStackViewAlignmentCenter;
    _toolsetRow.translatesAutoresizingMaskIntoConstraints = NO;

    _navigateButton = IconButton(@"cursorarrow", @"Cursor", static_cast<NSInteger>(pager::Tool::Scroll), self,
                                 @selector(selectNavigate:));
    UIButton *grip = IconButton(@"line.3.horizontal", @"Move Toolbar", 0, self, nil);
    grip.userInteractionEnabled = NO;
    UIView *setLine = Hairline();
    setLine.tag = 21;
    _styleDivider = Hairline();
    _styleDivider.tag = 22;
    _styleDivider.hidden = YES;
    _colorWell = [PagerChromeButton buttonWithType:UIButtonTypeCustom];
    _colorWell.showsMenuAsPrimaryAction = YES;
    _colorWell.changesSelectionAsPrimaryAction = NO;
    _colorWell.accessibilityLabel = @"Color";
    [_colorWell addTarget:self action:@selector(dismissSizePopup) forControlEvents:UIControlEventTouchDown];
    [_colorWell.widthAnchor constraintEqualToConstant:22].active = YES;
    [_colorWell.heightAnchor constraintEqualToConstant:22].active = YES;
    ApplyRoundedChrome(_colorWell, 11, YES);
    _sizeWell = [PagerChromeButton buttonWithType:UIButtonTypeCustom];
    _sizeWell.accessibilityLabel = @"Size";
    _sizeWell.tintColor = UIColor.labelColor;
    [_sizeWell setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    _sizeWell.contentEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [_sizeWell addTarget:self action:@selector(toggleSizePopup:) forControlEvents:UIControlEventTouchUpInside];
    [_sizeWell.widthAnchor constraintGreaterThanOrEqualToConstant:28].active = YES;
    [_sizeWell.heightAnchor constraintEqualToConstant:22].active = YES;
    ApplyCapsuleChrome(_sizeWell);
    _styleRow = [[UIStackView alloc] initWithArrangedSubviews:@[_colorWell, _sizeWell]];
    _styleRow.alignment = UIStackViewAlignmentCenter;
    _styleRow.spacing = 6;
    _styleRow.translatesAutoresizingMaskIntoConstraints = NO;
    _styleRow.hidden = YES;
    __weak ViewerViewController *weakStyle = self;
    ((PagerChromeButton *)_colorWell).onMenuDidEnd = ^{
        ViewerViewController *strongSelf = weakStyle;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf restoreChromeCorners];
        ApplyRoundedChrome(strongSelf->_colorWell, 11, YES);
    };
    _toolStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        grip, _navigateButton, setLine, _toolsetRow, _toolIcons, _styleDivider, _styleRow
    ]];
    _toolStack.alignment = UIStackViewAlignmentCenter;
    _toolStack.spacing = 6;
    _toolStack.translatesAutoresizingMaskIntoConstraints = NO;
    _toolDock = GlassPanel(22, YES);
    [_toolDock.contentView addSubview:_toolStack];
    UIPanGestureRecognizer *dockPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDockPan:)];
    dockPan.cancelsTouchesInView = NO;
    [_toolDock addGestureRecognizer:dockPan];

    _sidebarControl = [[UISegmentedControl alloc] initWithItems:@[@"Contents", @"Notes"]];
    _sidebarControl.selectedSegmentIndex = 0;
    _sidebarControl.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebarControl addTarget:self action:@selector(sidebarChanged:) forControlEvents:UIControlEventValueChanged];
    _outlineTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _outlineTable.translatesAutoresizingMaskIntoConstraints = NO;
    _outlineTable.dataSource = (id<UITableViewDataSource>)self;
    _outlineTable.delegate = (id<UITableViewDelegate>)self;
    _outlineTable.backgroundColor = UIColor.clearColor;
    _outlineTable.tag = 1;
    _notesTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _notesTable.translatesAutoresizingMaskIntoConstraints = NO;
    _notesTable.dataSource = (id<UITableViewDataSource>)self;
    _notesTable.delegate = (id<UITableViewDelegate>)self;
    _notesTable.backgroundColor = UIColor.clearColor;
    _notesTable.tag = 2;
    _notesTable.hidden = YES;
    _sidebar = GlassPanel(22, NO);
    [_sidebar.contentView addSubview:_sidebarControl];
    [_sidebar.contentView addSubview:_outlineTable];
    [_sidebar.contentView addSubview:_notesTable];
    _dimmer = [[UIView alloc] init];
    _dimmer.translatesAutoresizingMaskIntoConstraints = NO;
    _dimmer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    _dimmer.alpha = 0;
    UITapGestureRecognizer *dimmerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideSidebar:)];
    [_dimmer addGestureRecognizer:dimmerTap];

    [self.view addSubview:_scrollView];
    [self.view addSubview:_dimmer];
    [self.view addSubview:_sidebar];
    [self.view addSubview:_navPill];
    [self.view addSubview:_pagePill];
    [self.view addSubview:_searchPill];
    [self.view addSubview:_toolDock];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *corner = CornerSafeGuide(self.view);
    _searchCollapsedWidth = [_searchPill.widthAnchor constraintEqualToAnchor:_searchPill.heightAnchor];
    _searchExpandedWidth = [_searchPill.widthAnchor constraintEqualToConstant:360];
    _searchExpandedWidth.active = NO;
    _searchFieldMinWidth = [_searchField.widthAnchor constraintGreaterThanOrEqualToConstant:120];
    _searchFieldMinWidth.active = NO;
    _dockCenterX = [_toolDock.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor];
    _dockBottom = [_toolDock.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16];
    _dockLeading = [_toolDock.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12];
    _dockTrailing = [_toolDock.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12];
    _dockCenterY = [_toolDock.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor];
    _dockLeading.active = NO;
    _dockTrailing.active = NO;
    _dockCenterY.active = NO;
    _dockClearSidebar = [_toolDock.leadingAnchor constraintGreaterThanOrEqualToAnchor:_sidebar.trailingAnchor constant:10];
    _dockClearSidebar.active = NO;
    NSLayoutConstraint *pageCenterX = [_pagePill.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor];
    pageCenterX.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_navPill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        _navPillLeading = [_navPill.leadingAnchor constraintEqualToAnchor:corner.leadingAnchor constant:12],
        [navRow.leadingAnchor constraintEqualToAnchor:_navPill.contentView.leadingAnchor constant:6],
        [navRow.trailingAnchor constraintEqualToAnchor:_navPill.contentView.trailingAnchor constant:-6],
        [navRow.topAnchor constraintEqualToAnchor:_navPill.contentView.topAnchor constant:4],
        [navRow.bottomAnchor constraintEqualToAnchor:_navPill.contentView.bottomAnchor constant:-4],
        pageCenterX,
        [_pagePill.centerYAnchor constraintEqualToAnchor:_navPill.centerYAnchor],
        [_pagePill.leadingAnchor constraintGreaterThanOrEqualToAnchor:_navPill.trailingAnchor constant:10],
        [pageRow.leadingAnchor constraintEqualToAnchor:_pagePill.contentView.leadingAnchor constant:6],
        [pageRow.trailingAnchor constraintEqualToAnchor:_pagePill.contentView.trailingAnchor constant:-6],
        [pageRow.topAnchor constraintEqualToAnchor:_pagePill.contentView.topAnchor constant:4],
        [pageRow.bottomAnchor constraintEqualToAnchor:_pagePill.contentView.bottomAnchor constant:-4],
        [_pageLabel.widthAnchor constraintGreaterThanOrEqualToConstant:56],
        [_searchPill.centerYAnchor constraintEqualToAnchor:_navPill.centerYAnchor],
        [_searchPill.heightAnchor constraintEqualToAnchor:_navPill.heightAnchor],
        [_searchPill.trailingAnchor constraintEqualToAnchor:corner.trailingAnchor constant:-12],
        [_searchPill.leadingAnchor constraintGreaterThanOrEqualToAnchor:_pagePill.trailingAnchor constant:10],
        _searchCollapsedWidth,
        [searchRow.leadingAnchor constraintEqualToAnchor:_searchPill.contentView.leadingAnchor constant:4],
        [searchRow.trailingAnchor constraintEqualToAnchor:_searchPill.contentView.trailingAnchor constant:-4],
        [searchRow.topAnchor constraintEqualToAnchor:_searchPill.contentView.topAnchor constant:4],
        [searchRow.bottomAnchor constraintEqualToAnchor:_searchPill.contentView.bottomAnchor constant:-4],
        [_searchToggle.widthAnchor constraintEqualToAnchor:_searchToggle.heightAnchor],
        _dockCenterX,
        _dockBottom,
        [_toolStack.leadingAnchor constraintEqualToAnchor:_toolDock.contentView.leadingAnchor constant:8],
        [_toolStack.trailingAnchor constraintEqualToAnchor:_toolDock.contentView.trailingAnchor constant:-8],
        [_toolStack.topAnchor constraintEqualToAnchor:_toolDock.contentView.topAnchor constant:6],
        [_toolStack.bottomAnchor constraintEqualToAnchor:_toolDock.contentView.bottomAnchor constant:-6],
        [setLine.widthAnchor constraintEqualToConstant:1],
        [setLine.heightAnchor constraintEqualToConstant:18],
        [_dimmer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_dimmer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_dimmer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_dimmer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_sidebar.topAnchor constraintEqualToAnchor:_navPill.bottomAnchor constant:10],
        _sidebarLeading = [_sidebar.leadingAnchor constraintEqualToAnchor:corner.leadingAnchor constant:12],
        [_sidebar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [_sidebar.widthAnchor constraintEqualToConstant:280],
        [_sidebarControl.topAnchor constraintEqualToAnchor:_sidebar.contentView.topAnchor constant:12],
        [_sidebarControl.leadingAnchor constraintEqualToAnchor:_sidebar.contentView.leadingAnchor constant:12],
        [_sidebarControl.trailingAnchor constraintEqualToAnchor:_sidebar.contentView.trailingAnchor constant:-12],
        [_outlineTable.topAnchor constraintEqualToAnchor:_sidebarControl.bottomAnchor constant:8],
        [_outlineTable.leadingAnchor constraintEqualToAnchor:_sidebar.contentView.leadingAnchor],
        [_outlineTable.trailingAnchor constraintEqualToAnchor:_sidebar.contentView.trailingAnchor],
        [_outlineTable.bottomAnchor constraintEqualToAnchor:_sidebar.contentView.bottomAnchor],
        [_notesTable.topAnchor constraintEqualToAnchor:_outlineTable.topAnchor],
        [_notesTable.leadingAnchor constraintEqualToAnchor:_outlineTable.leadingAnchor],
        [_notesTable.trailingAnchor constraintEqualToAnchor:_outlineTable.trailingAnchor],
        [_notesTable.bottomAnchor constraintEqualToAnchor:_outlineTable.bottomAnchor],
    ]];

    [self applyDockEdge:_dockEdge animated:NO];
    [self applyToolset:_activeToolset];
    [self updateWindowControlInsets];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scrollToNote:) name:@"PagerScrollToPage" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notesChanged:) name:@"PagerNotesChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(selectionChanged:) name:@"PagerSelectionChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(toggleChrome:) name:@"PagerToggleChrome" object:nil];
    [self refreshToolButtons];
    [self applyChromeAnimated:NO];
}

- (void)restoreChromeCorners {
    ApplyRoundedChrome(_navPill, 20, YES);
    ApplyRoundedChrome(_pagePill, 20, YES);
    ApplyRoundedChrome(_searchPill, 20, YES);
    ApplyRoundedChrome(_toolDock, 22, YES);
    ApplyRoundedChrome(_sidebar, 22, NO);
    ApplyCapsuleChrome(_moreButton);
    ApplyCapsuleChrome(_sidebarButton);
}

- (void)updateWindowControlInsets {
    const CGFloat extra = WindowControlLeadingExtra(self.view);
    const CGFloat constant = 12 + extra;
    if (_navPillLeading.constant != constant) {
        _navPillLeading.constant = constant;
    }
    if (_sidebarLeading.constant != constant) {
        _sidebarLeading.constant = constant;
    }
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateWindowControlInsets];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateWindowControlInsets];
    [self restoreChromeCorners];
    [_canvas updateOverlay];
    if (_needsFitWidth && _document != nil && _scrollView.bounds.size.width >= 32) {
        _needsFitWidth = NO;
        [self fitWidth:nil];
    } else if (_document != nil) {
        [self updateZoomCentering];
    }
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *sidebar = [UIKeyCommand keyCommandWithInput:@"1"
                                                modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate
                                                       action:@selector(toggleSidebar:)];
    sidebar.discoverabilityTitle = @"Toggle Sidebar";
    UIKeyCommand *chrome = [UIKeyCommand keyCommandWithInput:@"0"
                                               modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate
                                                      action:@selector(toggleChrome:)];
    chrome.discoverabilityTitle = @"Toggle Controls";
    UIKeyCommand *find = [UIKeyCommand keyCommandWithInput:@"f" modifierFlags:UIKeyModifierCommand action:@selector(focusSearch:)];
    find.discoverabilityTitle = @"Find";
    UIKeyCommand *undo = [UIKeyCommand keyCommandWithInput:@"z" modifierFlags:UIKeyModifierCommand action:@selector(undo:)];
    undo.discoverabilityTitle = @"Undo";
    UIKeyCommand *redo = [UIKeyCommand keyCommandWithInput:@"z"
                                             modifierFlags:UIKeyModifierCommand | UIKeyModifierShift
                                                    action:@selector(redo:)];
    redo.discoverabilityTitle = @"Redo";
    UIKeyCommand *del = [UIKeyCommand keyCommandWithInput:@"\b" modifierFlags:0 action:@selector(deleteNote:)];
    del.discoverabilityTitle = @"Delete Note";
    UIKeyCommand *fit = [UIKeyCommand keyCommandWithInput:@"9"
                                            modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate
                                                   action:@selector(fitWidth:)];
    fit.discoverabilityTitle = @"Zoom to Width";
    UIKeyCommand *escape = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0
                                                     action:@selector(dismissHighlights:)];
    escape.discoverabilityTitle = @"Clear Highlights";
    return @[sidebar, chrome, find, undo, redo, del, fit, escape];
}

- (void)openDocument:(id)sender {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePDF]];
    picker.delegate = (id<UIDocumentPickerDelegate>)self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSURL *)writeSamplePDF {
    NSString *name = [NSString stringWithFormat:@"PagerSample-%.0f.pdf", [NSDate date].timeIntervalSince1970];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    const CGRect box = CGRectMake(0, 0, 612, 792);
    UIGraphicsBeginPDFContextToFile(url.path, box, nil);
    NSArray<NSString *> *bodies = @[
        @"The quick brown fox jumps over the lazy dog. Pinch the page: after you lift, the type should stay sharp, not a stretched bitmap. Drag across this sentence to highlight it.",
        @"Page two is here so scrolling and page-step stay honest. Draw a square, a line, or a pencil stroke over this paragraph. The mark should sit on the words after zoom.",
        @"A third page keeps the document taller than the viewport. Fit-width, pinch, and annotate again. Notes are a sidecar, like Skim: they stay after you change tools."
    ];
    for (NSUInteger index = 0; index < bodies.count; ++index) {
        UIGraphicsBeginPDFPage();
        NSString *title = [NSString stringWithFormat:@"Pager Sample  ·  Page %lu", (unsigned long)(index + 1)];
        [title drawInRect:CGRectMake(64, 64, 480, 40)
           withAttributes:@{NSFontAttributeName : [UIFont boldSystemFontOfSize:26],
                            NSForegroundColorAttributeName : UIColor.blackColor}];
        [bodies[index] drawInRect:CGRectMake(64, 120, 484, 520)
                   withAttributes:@{NSFontAttributeName : [UIFont systemFontOfSize:18],
                                    NSForegroundColorAttributeName : UIColor.blackColor}];
    }
    UIGraphicsEndPDFContext();
    return url;
}

- (void)openSampleDocument:(id)sender {
    [self openURL:[self writeSamplePDF]];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.firstObject != nil) {
        [self openURL:urls.firstObject];
    }
}

- (void)openURL:(NSURL *)url {
    [_canvas detachViewport];
    PadDocument *previous = _document;
    _document = nil;
    [previous closeWithCompletionHandler:nil];
    [_outlineTable reloadData];
    [_notesTable reloadData];
    [_canvas setNeedsDisplay];
    [self updatePageLabel];
    PadDocument *document = [[PadDocument alloc] initWithFileURL:url];
    __weak ViewerViewController *weakSelf = self;
    [document openWithCompletionHandler:^(BOOL success) {
        ViewerViewController *strongSelf = weakSelf;
        if (!success || strongSelf == nil) {
            return;
        }
        strongSelf->_document = document;
        document.session.setTool(strongSelf->_tool);
        [strongSelf refreshStyleBar];
        const CGFloat scale = strongSelf.view.window.windowScene.screen.scale;
        document.session.viewport().setScreenScale(scale > 0 ? scale : 2);
        [strongSelf->_scrollView setZoomScale:1 animated:NO];
        [strongSelf->_canvas attachToDocument:document];
        [strongSelf->_outlineTable reloadData];
        [strongSelf->_notesTable reloadData];
        [strongSelf updatePageLabel];
        strongSelf->_needsFitWidth = YES;
        if (strongSelf->_scrollView.bounds.size.width >= 32) {
            strongSelf->_needsFitWidth = NO;
            [strongSelf fitWidth:nil];
        }
    }];
}

- (void)refreshToolButtons {
    StyleSelected(_navigateButton, _tool == pager::Tool::Scroll);
    for (UIButton *button in _toolButtons) {
        StyleSelected(button, button.tag == static_cast<NSInteger>(_tool) && _tool != pager::Tool::Scroll);
    }
    for (UIButton *button in _toolsetButtons) {
        StyleSelected(button, button.tag == _activeToolset);
    }
}

- (void)applyTool:(pager::Tool)tool {
    if (tool != _tool) {
        [_canvas endTextEditing];
    }
    if (tool == _tool) {
        [self refreshToolButtons];
        [self refreshStyleBar];
        return;
    }
    _previousTool = _tool;
    _tool = tool;
    if (_tool == pager::Tool::Pen || _tool == pager::Tool::Marker) {
        _lastDrawTool = _tool;
    }
    if (_tool != pager::Tool::Scroll && _tool != pager::Tool::SelectNote && _tool != pager::Tool::SelectText) {
        _activeToolset = ToolsetForTool(_tool);
        _lastToolInSet[_activeToolset] = _tool;
    }
    if (_document != nil) {
        _document.session.setTool(_tool);
    }
    [self applyToolset:_activeToolset];
    [self syncScrollEnabled];
    [self refreshToolButtons];
    [self refreshStyleBar];
}

- (void)syncScrollEnabled {
#if TARGET_OS_SIMULATOR
    // No Pencil touch type: annotation tools need the drag, so only Navigate pans.
    _scrollView.scrollEnabled = _tool == pager::Tool::Scroll;
    _scrollView.canCancelContentTouches = _tool == pager::Tool::Scroll;
#else
    // Finger always pans. Pencil annotates; the canvas pauses the pan recognizer
    // only while a stroke or shape is actually in flight.
    _scrollView.scrollEnabled = YES;
    _scrollView.canCancelContentTouches = YES;
#endif
    _scrollView.pinchGestureRecognizer.enabled = YES;
}

- (void)selectNavigate:(id)sender {
    [self applyTool:pager::Tool::Scroll];
}

- (void)selectTool:(UIButton *)sender {
    const pager::Tool tool = static_cast<pager::Tool>(sender.tag);
    if (tool == _tool) {
        [self applyTool:pager::Tool::Scroll];
        return;
    }
    [self applyTool:tool];
}

- (void)pencilInteractionDidTap:(UIPencilInteraction *)interaction {
    const UIPencilPreferredAction action = UIPencilInteraction.preferredTapAction;
    if (action == UIPencilPreferredActionIgnore) {
        return;
    }
    if (action == UIPencilPreferredActionSwitchPrevious && _previousTool != _tool) {
        [self applyTool:_previousTool];
        return;
    }
    // Default (and "show color palette", which we have no palette for): toggle pen/eraser.
    if (_tool == pager::Tool::Eraser) {
        [self applyTool:_lastDrawTool];
    } else if (_tool == pager::Tool::Pen || _tool == pager::Tool::Marker) {
        [self applyTool:pager::Tool::Eraser];
    } else {
        [self applyTool:_lastDrawTool];
    }
}

- (IBAction)sidebarChanged:(UISegmentedControl *)sender {
    const BOOL notes = sender.selectedSegmentIndex == 1;
    _outlineTable.hidden = notes;
    _notesTable.hidden = !notes;
}

- (void)anchorPopover:(UIViewController *)controller fromButton:(UIButton *)button {
    UIPopoverPresentationController *popover = controller.popoverPresentationController;
    if (popover == nil) {
        return;
    }
    UIButton *anchor = button ?: _moreButton;
    popover.sourceView = anchor;
    popover.sourceRect = anchor.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionUp | UIPopoverArrowDirectionDown;
}

- (void)presentAfterMenu:(void (^)(void))work {
    // The list menu is already closing. Dismissing again flashes the document
    // and delays the next sheet (Open / Export).
    [self restoreChromeCorners];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restoreChromeCorners];
        if (work != nil) {
            work();
        }
        [self restoreChromeCorners];
    });
}

- (UIMenu *)moreMenu {
    __weak ViewerViewController *weakSelf = self;
    UIDeferredMenuElement *deferred =
        [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *elements)) {
            ViewerViewController *strongSelf = weakSelf;
            completion(strongSelf == nil ? @[] : [strongSelf moreMenuElements]);
        }];
    return [UIMenu menuWithChildren:@[deferred]];
}

- (NSArray<UIMenuElement *> *)moreMenuElements {
    __weak ViewerViewController *weakSelf = self;
    UIAction * (^item)(NSString *, NSString *, BOOL, BOOL, void (^)(ViewerViewController *)) =
        ^(NSString *title, NSString *symbol, BOOL enabled, BOOL destructive, void (^work)(ViewerViewController *)) {
            UIAction *action = [UIAction actionWithTitle:title
                                                   image:Symbol(symbol, 17)
                                              identifier:nil
                                                 handler:^(__unused UIAction *incoming) {
                                                     [weakSelf presentAfterMenu:^{
                                                         ViewerViewController *strongSelf = weakSelf;
                                                         if (strongSelf != nil) {
                                                             work(strongSelf);
                                                         }
                                                     }];
                                                 }];
            UIMenuElementAttributes attributes = 0;
            if (!enabled) {
                attributes |= UIMenuElementAttributesDisabled;
            }
            if (destructive) {
                attributes |= UIMenuElementAttributesDestructive;
            }
            action.attributes = attributes;
            return action;
        };
    const BOOL hasDoc = _document != nil;
    const BOOL canUndo = hasDoc && _document.session.notes().canUndo();
    const BOOL canRedo = hasDoc && _document.session.notes().canRedo();
    const BOOL canDelete = hasDoc && _document.session.selectedNote().value != 0;
    UIAction *open = item(@"Open…", @"folder", YES, NO, ^(ViewerViewController *self_) {
        [self_ openDocument:nil];
    });
    UIAction *sample = item(@"Sample PDF", @"doc.richtext", YES, NO, ^(ViewerViewController *self_) {
        [self_ openSampleDocument:nil];
    });
    UIAction *undo = item(@"Undo", @"arrow.uturn.backward", canUndo, NO, ^(ViewerViewController *self_) {
        [self_ undo:nil];
    });
    UIAction *redo = item(@"Redo", @"arrow.uturn.forward", canRedo, NO, ^(ViewerViewController *self_) {
        [self_ redo:nil];
    });
    UIAction *del = item(@"Delete Note", @"trash", canDelete, YES, ^(ViewerViewController *self_) {
        [self_ deleteNote:nil];
    });
    UIAction *flatten = item(@"Export…", @"square.and.arrow.up", hasDoc, NO, ^(ViewerViewController *self_) {
        [self_ flatten:self_->_moreButton];
    });
    UIAction *fit = item(@"Fit Width", @"arrow.up.left.and.arrow.down.right", hasDoc, NO, ^(ViewerViewController *self_) {
        [self_ fitWidth:self_];
    });
    return @[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[open, sample]],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[undo, redo, del]],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[flatten, fit]],
    ];
}

- (void)selectToolset:(UIButton *)sender {
    [self applyToolset:sender.tag];
    NSInteger count = 0;
    const pager::Tool *tools = ToolsForSet(sender.tag, &count);
    pager::Tool next = _lastToolInSet[sender.tag];
    BOOL found = NO;
    for (NSInteger index = 0; index < count; ++index) {
        if (tools[index] == next) {
            found = YES;
            break;
        }
    }
    if (!found && count > 0) {
        next = tools[0];
    }
    [self applyTool:next];
}

- (void)applyToolset:(NSInteger)set {
    if (set == kToolsetRead) {
        set = kToolsetDraw;
    }
    _activeToolset = set;
    NSInteger count = 0;
    const pager::Tool *tools = ToolsForSet(set, &count);
    for (UIButton *button in _toolButtons) {
        BOOL visible = NO;
        for (NSInteger index = 0; index < count; ++index) {
            if (button.tag == static_cast<NSInteger>(tools[index])) {
                visible = YES;
                break;
            }
        }
        button.hidden = !visible;
    }
    [self refreshToolButtons];
    [self refreshStyleBar];
}

- (void)fillStylePaletteForTool:(pager::Tool)styleTool {
    _styleColors.clear();
    _styleSizes.clear();
    auto addColor = [&](float r, float g, float b, float a) {
        _styleColors.push_back(pager::Color{r, g, b, a});
    };
    if (styleTool == pager::Tool::Marker) {
        addColor(1, 0.85f, 0.1f, 0.45f);
        addColor(1, 0.35f, 0.55f, 0.45f);
        addColor(0.35f, 0.85f, 0.35f, 0.45f);
        addColor(0.25f, 0.55f, 1, 0.45f);
        addColor(1, 0.55f, 0.15f, 0.45f);
    } else if (styleTool == pager::Tool::Highlight) {
        addColor(1, 0.84f, 0.12f, 0.42f);
        addColor(0.45f, 0.9f, 0.3f, 0.42f);
        addColor(1, 0.4f, 0.7f, 0.42f);
        addColor(0.35f, 0.65f, 1, 0.42f);
        addColor(1, 0.55f, 0.15f, 0.42f);
    } else if (styleTool == pager::Tool::Pen) {
        addColor(0.05f, 0.05f, 0.05f, 1);
        addColor(0.45f, 0.45f, 0.48f, 1);
        addColor(0.1f, 0.35f, 0.9f, 1);
        addColor(0.85f, 0.12f, 0.12f, 1);
        addColor(0.1f, 0.55f, 0.2f, 1);
        addColor(0.45f, 0.2f, 0.75f, 1);
    } else {
        addColor(0.12f, 0.12f, 0.14f, 1);
        addColor(0.1f, 0.35f, 0.9f, 1);
        addColor(0.85f, 0.12f, 0.12f, 1);
        addColor(0.1f, 0.55f, 0.2f, 1);
        addColor(0.9f, 0.45f, 0.1f, 1);
        addColor(0.45f, 0.2f, 0.75f, 1);
    }
    if (styleTool == pager::Tool::FreeText) {
        _styleSizes = {11, 14, 18, 24};
    } else if (styleTool == pager::Tool::Pen) {
        _styleSizes = {1.4f, 2.2f, 3.6f};
    } else if (styleTool == pager::Tool::Marker) {
        _styleSizes = {8, 14, 22};
    } else if (styleTool == pager::Tool::Square || styleTool == pager::Tool::Circle || styleTool == pager::Tool::Line) {
        _styleSizes = {1, 2, 4};
    }
}

- (void)currentStyleTool:(pager::Tool *)tool color:(pager::Color *)color size:(float *)size {
    pager::Tool styleTool = _tool;
    const pager::Annotation *selected = _document == nil ? nullptr : _document.session.selectedAnnotation();
    if (selected != nullptr) {
        styleTool = ToolForKind(selected->kind);
    }
    const pager::ToolStyle fallback = pager::DefaultStyleForTool(styleTool);
    pager::Color current = fallback.color;
    float currentSize = styleTool == pager::Tool::FreeText ? fallback.fontSize : fallback.lineWidth;
    if (selected != nullptr) {
        current = selected->color;
        currentSize = styleTool == pager::Tool::FreeText ? selected->fontSize : selected->lineWidth;
    } else if (_document != nil) {
        const pager::ToolStyle style = _document.session.toolStyle(styleTool);
        current = style.color;
        currentSize = styleTool == pager::Tool::FreeText ? style.fontSize : style.lineWidth;
    }
    if (tool != nullptr) {
        *tool = styleTool;
    }
    if (color != nullptr) {
        *color = current;
    }
    if (size != nullptr) {
        *size = currentSize;
    }
}

- (void)refreshStyleBar {
    if (_styleRow == nil || _colorWell == nil) {
        return;
    }
    const BOOL wasHidden = _styleRow.hidden;
    pager::Tool styleTool = _tool;
    pager::Color current{};
    float currentSize = 0;
    [self currentStyleTool:&styleTool color:&current size:&currentSize];
    const BOOL showColors = styleTool == pager::Tool::Highlight || styleTool == pager::Tool::Underline ||
                            styleTool == pager::Tool::StrikeOut || styleTool == pager::Tool::Square ||
                            styleTool == pager::Tool::Circle || styleTool == pager::Tool::Line ||
                            styleTool == pager::Tool::FreeText || styleTool == pager::Tool::Pen ||
                            styleTool == pager::Tool::Marker;
    if (showColors) {
        [self fillStylePaletteForTool:styleTool];
        _colorWell.backgroundColor = UIColorFromPager(current);
        ApplyRoundedChrome(_colorWell, 11, YES);
        __weak ViewerViewController *weakSelf = self;
        NSMutableArray<UIMenuElement *> *colorItems = [NSMutableArray array];
        for (size_t index = 0; index < _styleColors.size(); ++index) {
            const pager::Color color = _styleColors[index];
            const BOOL on = std::fabs(color.r - current.r) < 0.08f && std::fabs(color.g - current.g) < 0.08f &&
                            std::fabs(color.b - current.b) < 0.08f;
            UIAction *action = [UIAction actionWithTitle:@""
                                                   image:ColorDot(color)
                                              identifier:nil
                                                 handler:^(__unused UIAction *incoming) {
                                                     [weakSelf applyStyleColorValue:color];
                                                 }];
            if (on) {
                action.state = UIMenuElementStateOn;
            }
            [colorItems addObject:action];
        }
        UIMenu *colorMenu = [UIMenu menuWithTitle:@"" children:colorItems];
        colorMenu.preferredElementSize = UIMenuElementSizeSmall;
        _colorWell.menu = colorMenu;
        if (_styleSizes.empty()) {
            _sizeWell.hidden = YES;
        } else {
            _sizeWell.hidden = NO;
            NSArray<NSString *> *labels = SizeChipLabels(_styleSizes, styleTool);
            NSString *currentLabel = labels.firstObject ?: @"M";
            for (size_t index = 0; index < _styleSizes.size() && index < labels.count; ++index) {
                if (std::fabs(_styleSizes[index] - currentSize) < 0.26f) {
                    currentLabel = labels[index];
                    break;
                }
            }
            [_sizeWell setTitle:currentLabel forState:UIControlStateNormal];
            [_sizeWell setImage:nil forState:UIControlStateNormal];
            _sizeWell.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            ApplyCapsuleChrome(_sizeWell);
        }
    }
    const BOOL hide = !showColors;
    if (hide) {
        [self dismissSizePopupAnimated:NO];
    }
    if (hide == wasHidden) {
        return;
    }
    [self.view layoutIfNeeded];
    void (^apply)(void) = ^{
        self->_styleRow.hidden = hide;
        self->_styleDivider.hidden = hide;
        [self.view layoutIfNeeded];
    };
    if (self.view.window != nil) {
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.84 initialSpringVelocity:0.45
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:apply
                         completion:nil];
    } else {
        apply();
    }
}

- (void)toggleSizePopup:(id)sender {
    if (_sizePopup != nil) {
        [self dismissSizePopupAnimated:YES];
        return;
    }
    if (_styleSizes.empty()) {
        return;
    }
    pager::Tool styleTool = _tool;
    float currentSize = 0;
    [self currentStyleTool:&styleTool color:nullptr size:&currentSize];
    NSArray<NSString *> *labels = SizeChipLabels(_styleSizes, styleTool);
    NSMutableArray<UIView *> *chips = [NSMutableArray array];
    for (size_t index = 0; index < _styleSizes.size(); ++index) {
        const float size = _styleSizes[index];
        NSString *title = index < labels.count ? labels[index] : [NSString stringWithFormat:@"%.0f", size];
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        [chip setTitle:title forState:UIControlStateNormal];
        [chip setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        chip.tag = static_cast<NSInteger>(index);
        chip.accessibilityLabel = title;
        [chip.widthAnchor constraintEqualToConstant:40].active = YES;
        [chip.heightAnchor constraintEqualToConstant:40].active = YES;
        if (std::fabs(size - currentSize) < 0.26f) {
            chip.backgroundColor = UIColor.systemBlueColor;
            [chip setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            ApplyRoundedChrome(chip, 20, YES);
        }
        [chip addTarget:self action:@selector(selectSizePopup:) forControlEvents:UIControlEventTouchUpInside];
        [chips addObject:chip];
    }
    _sizePopupScrim = [[UIControl alloc] initWithFrame:self.view.bounds];
    _sizePopupScrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _sizePopupScrim.backgroundColor = UIColor.clearColor;
    [_sizePopupScrim addTarget:self action:@selector(dismissSizePopup) forControlEvents:UIControlEventTouchUpInside];
    [self.view insertSubview:_sizePopupScrim belowSubview:_toolDock];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:chips];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 4;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    _sizePopup = GlassPanel(22, YES);
    [_sizePopup.contentView addSubview:row];
    [self.view addSubview:_sizePopup];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:_sizePopup.contentView.leadingAnchor constant:8],
        [row.trailingAnchor constraintEqualToAnchor:_sizePopup.contentView.trailingAnchor constant:-8],
        [row.topAnchor constraintEqualToAnchor:_sizePopup.contentView.topAnchor constant:6],
        [row.bottomAnchor constraintEqualToAnchor:_sizePopup.contentView.bottomAnchor constant:-6],
    ]];
    [self.view layoutIfNeeded];
    const CGSize popupSize = [_sizePopup systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGRect well = [_sizeWell convertRect:_sizeWell.bounds toView:self.view];
    CGRect dock = _toolDock.frame;
    CGFloat x = CGRectGetMidX(well) - popupSize.width * 0.5;
    CGFloat y = CGRectGetMinY(dock) - 10 - popupSize.height;
    if (_dockEdge == kDockLeading) {
        x = CGRectGetMaxX(dock) + 10;
        y = CGRectGetMidY(well) - popupSize.height * 0.5;
    } else if (_dockEdge == kDockTrailing) {
        x = CGRectGetMinX(dock) - 10 - popupSize.width;
        y = CGRectGetMidY(well) - popupSize.height * 0.5;
    }
    x = std::clamp(x, (CGFloat)12, self.view.bounds.size.width - popupSize.width - 12);
    y = std::max((CGFloat)12, y);
    _sizePopup.translatesAutoresizingMaskIntoConstraints = YES;
    _sizePopup.frame = CGRectMake(x, y, popupSize.width, popupSize.height);
    _sizePopup.alpha = 0;
    _sizePopup.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         self->_sizePopup.alpha = 1;
                         self->_sizePopup.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
}

- (void)selectSizePopup:(UIButton *)sender {
    const NSInteger index = sender.tag;
    if (index < 0 || static_cast<size_t>(index) >= _styleSizes.size()) {
        [self dismissSizePopupAnimated:YES];
        return;
    }
    [self applyStyleSizeValue:_styleSizes[static_cast<size_t>(index)]];
    [self dismissSizePopupAnimated:YES];
}

- (void)dismissSizePopup {
    [self dismissSizePopupAnimated:YES];
}

- (void)dismissSizePopupAnimated:(BOOL)animated {
    UIVisualEffectView *popup = _sizePopup;
    UIControl *scrim = _sizePopupScrim;
    _sizePopup = nil;
    _sizePopupScrim = nil;
    if (popup == nil && scrim == nil) {
        return;
    }
    void (^remove)(void) = ^{
        [popup removeFromSuperview];
        [scrim removeFromSuperview];
    };
    if (!animated || popup == nil) {
        remove();
        return;
    }
    [UIView animateWithDuration:0.16 animations:^{
        popup.alpha = 0;
        popup.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(__unused BOOL finished) {
        remove();
    }];
}

- (void)applyStyleColorValue:(pager::Color)color {
    if (_document == nil) {
        return;
    }
    pager::Tool styleTool = _tool;
    pager::Annotation *selected = _document.session.selectedAnnotationMutable();
    if (selected != nullptr) {
        _document.session.notes().snapshot();
        selected->color = color;
        styleTool = ToolForKind(selected->kind);
        [_document saveNotes];
    }
    pager::ToolStyle style = _document.session.toolStyle(styleTool);
    style.color = color;
    _document.session.setToolStyle(styleTool, style);
    [_canvas setNeedsDisplay];
    [_canvas syncTextEditorStyle];
    [self refreshStyleBar];
    [self notesChanged:nil];
}

- (void)applyStyleSizeValue:(float)size {
    if (_document == nil) {
        return;
    }
    pager::Tool styleTool = _tool;
    pager::Annotation *selected = _document.session.selectedAnnotationMutable();
    if (selected != nullptr) {
        _document.session.notes().snapshot();
        styleTool = ToolForKind(selected->kind);
        if (selected->kind == pager::AnnotationKind::FreeText) {
            selected->fontSize = size;
        } else {
            selected->lineWidth = size;
        }
        [_document saveNotes];
    }
    pager::ToolStyle style = _document.session.toolStyle(styleTool);
    if (styleTool == pager::Tool::FreeText) {
        style.fontSize = size;
    } else {
        style.lineWidth = size;
    }
    _document.session.setToolStyle(styleTool, style);
    [_canvas setNeedsDisplay];
    [_canvas syncTextEditorStyle];
    [self refreshStyleBar];
    [self notesChanged:nil];
}

- (void)applyDockEdge:(NSInteger)edge animated:(BOOL)animated {
    _dockEdge = edge;
    [NSUserDefaults.standardUserDefaults setInteger:edge forKey:kPagerDockEdgeKey];
    const BOOL vertical = edge != kDockBottom;
    _toolStack.axis = vertical ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    _toolsetRow.axis = _toolStack.axis;
    _toolIcons.axis = _toolStack.axis;
    _styleRow.axis = _toolStack.axis;
    for (NSInteger tag = 21; tag <= 22; ++tag) {
        UIView *line = [_toolDock.contentView viewWithTag:tag];
        if (line == nil) {
            continue;
        }
        [line removeConstraints:line.constraints];
        if (vertical) {
            [line.widthAnchor constraintEqualToConstant:18].active = YES;
            [line.heightAnchor constraintEqualToConstant:1].active = YES;
        } else {
            [line.widthAnchor constraintEqualToConstant:1].active = YES;
            [line.heightAnchor constraintEqualToConstant:18].active = YES;
        }
    }
    _dockCenterX.active = edge == kDockBottom;
    _dockBottom.active = edge == kDockBottom;
    _dockLeading.active = edge == kDockLeading;
    _dockTrailing.active = edge == kDockTrailing;
    _dockCenterY.active = vertical;
    _dockClearSidebar.active = _sidebarVisible && edge == kDockBottom;
    void (^apply)(void) = ^{
        [self.view layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4 options:0 animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)handleDockPan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        _dockDragOrigin = _toolDock.center;
        _dockCenterX.active = NO;
        _dockBottom.active = NO;
        _dockLeading.active = NO;
        _dockTrailing.active = NO;
        _dockCenterY.active = NO;
    }
    const CGPoint translation = [pan translationInView:self.view];
    _toolDock.center = CGPointMake(_dockDragOrigin.x + translation.x, _dockDragOrigin.y + translation.y);
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    const CGPoint point = _toolDock.center;
    const CGFloat width = self.view.bounds.size.width;
    const CGFloat height = self.view.bounds.size.height;
    const CGFloat left = point.x;
    const CGFloat right = width - point.x;
    const CGFloat bottom = height - point.y;
    NSInteger edge = kDockBottom;
    if (left < right && left < bottom) {
        edge = kDockLeading;
    } else if (right < left && right < bottom) {
        edge = kDockTrailing;
    }
    [self applyDockEdge:edge animated:YES];
}

- (void)toggleSearch:(id)sender {
    if (_searchExpanded) {
        [self cancelSearch:sender];
        return;
    }
    [self setSearchExpanded:YES animated:YES];
    [_searchField becomeFirstResponder];
}

- (void)setSearchExpanded:(BOOL)expanded animated:(BOOL)animated {
    _searchExpanded = expanded;
    _searchCollapsedWidth.active = !expanded;
    _searchExpandedWidth.active = expanded;
    _searchFieldMinWidth.active = expanded;
    for (UIView *view in _searchPill.contentView.subviews) {
        if (![view isKindOfClass:[UIStackView class]]) {
            continue;
        }
        UIStackView *row = (UIStackView *)view;
        for (UIView *child in row.arrangedSubviews) {
            if (child == _searchToggle) {
                continue;
            }
            child.hidden = !expanded;
        }
    }
    void (^apply)(void) = ^{
        [self.view layoutIfNeeded];
    };
    _searchToggle.accessibilityLabel = expanded ? @"Close Search" : @"Find";
    if (animated) {
        [UIView animateWithDuration:0.22 animations:apply];
    } else {
        apply();
    }
}

- (void)hideSidebar:(id)sender {
    if (_sidebarVisible) {
        [self toggleSidebar:sender];
    }
}

- (void)applyChromeAnimated:(BOOL)animated {
    if (_sidebarVisible) {
        _sidebar.hidden = NO;
        _dimmer.hidden = NO;
    }
    if (!_chromeVisible) {
        [self dismissSizePopupAnimated:NO];
    }
    if (_chromeVisible) {
        _navPill.hidden = NO;
        _searchPill.hidden = NO;
    }
    _pagePill.hidden = NO;
    _dockClearSidebar.active = NO;
    const BOOL showDock = _chromeVisible && !_sidebarVisible;
    _toolDock.hidden = !showDock;
    StyleSelected(_sidebarButton, _sidebarVisible);
    void (^apply)(void) = ^{
        self->_sidebar.alpha = self->_sidebarVisible ? 1 : 0;
        self->_dimmer.alpha = self->_sidebarVisible ? 1 : 0;
        self->_navPill.alpha = self->_chromeVisible ? 1 : 0;
        self->_searchPill.alpha = self->_chromeVisible ? 1 : 0;
        self->_toolDock.alpha = showDock ? 1 : 0;
        self->_toolDock.transform = showDock ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(0, 90);
        self->_pagePill.alpha = 1;
        [self.view layoutIfNeeded];
        [self restoreChromeCorners];
    };
    if (animated) {
        [UIView animateWithDuration:0.22 animations:apply completion:^(BOOL finished) {
            self->_sidebar.hidden = !self->_sidebarVisible;
            self->_dimmer.hidden = !self->_sidebarVisible;
            self->_navPill.hidden = !self->_chromeVisible;
            self->_searchPill.hidden = !self->_chromeVisible;
            self->_toolDock.hidden = !showDock;
            [self restoreChromeCorners];
            [self->_canvas updateVisibleRect];
        }];
    } else {
        apply();
        _sidebar.hidden = !_sidebarVisible;
        _dimmer.hidden = !_sidebarVisible;
        _navPill.hidden = !_chromeVisible;
        _searchPill.hidden = !_chromeVisible;
        _toolDock.hidden = !showDock;
        [self restoreChromeCorners];
        [_canvas updateVisibleRect];
    }
}

- (void)toggleSidebar:(id)sender {
    _sidebarVisible = !_sidebarVisible;
    [NSUserDefaults.standardUserDefaults setBool:_sidebarVisible forKey:kPagerSidebarVisibleKey];
    [self applyChromeAnimated:YES];
}

- (void)toggleChrome:(id)sender {
    _chromeVisible = !_chromeVisible;
    [NSUserDefaults.standardUserDefaults setBool:_chromeVisible forKey:kPagerChromeVisibleKey];
    [self applyChromeAnimated:YES];
}

- (void)focusSearch:(id)sender {
    if (!_chromeVisible) {
        _chromeVisible = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kPagerChromeVisibleKey];
        [self applyChromeAnimated:YES];
    }
    [self setSearchExpanded:YES animated:YES];
    [_searchField becomeFirstResponder];
}

- (int)pageIndexNearDocumentPoint:(pager::Point)point {
    const pager::Layout &layout = _document.session.viewport().layout();
    const int hit = layout.pageAt(point);
    if (hit >= 0) {
        return hit;
    }
    int found = -1;
    double best = 1e12;
    for (const pager::PageFrame &frame : layout.pages()) {
        double distance = 0;
        if (point.y < frame.frame.y) {
            distance = frame.frame.y - point.y;
        } else if (point.y > frame.frame.y + frame.frame.height) {
            distance = point.y - (frame.frame.y + frame.frame.height);
        }
        if (distance < best) {
            best = distance;
            found = frame.index;
        }
    }
    return found;
}

- (int)currentPageIndex {
    if (_document == nil) {
        return -1;
    }
    const pager::Layout &layout = _document.session.viewport().layout();
    const CGFloat zoom = std::max(0.05, _scrollView.zoomScale);
    const double y0 = _scrollView.contentOffset.y / zoom;
    const double y1 = (_scrollView.contentOffset.y + _scrollView.bounds.size.height) / zoom;
    const double x = (_scrollView.contentOffset.x + _scrollView.bounds.size.width * 0.5) / zoom;
    int best = -1;
    double bestVisible = 0;
    for (const pager::PageFrame &frame : layout.pages()) {
        const double vis0 = std::max(frame.frame.y, y0);
        const double vis1 = std::min(frame.frame.y + frame.frame.height, y1);
        const double visible = vis1 - vis0;
        if (visible > bestVisible) {
            bestVisible = visible;
            best = frame.index;
        }
    }
    if (best >= 0) {
        return best;
    }
    return [self pageIndexNearDocumentPoint:pager::Point{x, y0}];
}

- (void)updatePageLabel {
    if (_document == nil) {
        _pageLabel.text = @"—";
        return;
    }
    const int page = [self currentPageIndex];
    const int count = static_cast<int>(_document.session.viewport().pages().size());
    if (page < 0 || count <= 0) {
        _pageLabel.text = [NSString stringWithFormat:@"— / %d", count];
        return;
    }
    _pageLabel.text = [NSString stringWithFormat:@"%d / %d", page + 1, count];
}

- (void)stepPage:(NSInteger)delta {
    if (_document == nil) {
        return;
    }
    const int count = static_cast<int>(_document.session.viewport().pages().size());
    if (count <= 0) {
        return;
    }
    int page = [self currentPageIndex];
    if (page < 0) {
        page = 0;
    }
    page = std::clamp(page + static_cast<int>(delta), 0, count - 1);
    const pager::Rect frame = _document.session.viewport().layout().pageFrame(page);
    [self scrollDocumentPoint:pager::Point{frame.x + frame.width * 0.5, frame.y} toViewportY:8];
}

- (void)previousPage:(id)sender {
    [self stepPage:-1];
}

- (void)nextPage:(id)sender {
    [self stepPage:1];
}

- (CGFloat)fitWidthZoom {
    if (_document == nil || _scrollView.bounds.size.width < 32) {
        return 1;
    }
    const pager::Size content = _document.session.viewport().layout().contentSize();
    if (content.width <= 1) {
        return 1;
    }
    return static_cast<CGFloat>(
        pager::ClampScale(_scrollView.bounds.size.width / content.width));
}

- (void)fitWidth:(id)sender {
    if (_document == nil) {
        return;
    }
    int page = [self currentPageIndex];
    if (page < 0) {
        page = 0;
    }
    if (_scrollView.bounds.size.width < 32) {
        _needsFitWidth = YES;
        return;
    }
    const pager::Rect frame = _document.session.viewport().layout().pageFrame(page);
    const pager::Size content = _document.session.viewport().layout().contentSize();
    const CGFloat width = content.width > 1 ? content.width : std::max(1.0, frame.width);
    const CGFloat height =
        _scrollView.bounds.size.height * width / std::max(1.0, static_cast<double>(_scrollView.bounds.size.width));
    const CGRect zoomRect = CGRectMake(0, std::max(0.0, frame.y - 8), width, height);
    if (sender == nil) {
        [_canvas syncFrameAndTiles];
        [_scrollView zoomToRect:zoomRect animated:NO];
        _document.session.viewport().setScale(_scrollView.zoomScale);
        [self updateZoomCentering];
        [_canvas updateVisibleRect];
        [self updatePageLabel];
        return;
    }
    // Do not rewrite the zoom view's frame here: that fights UIScrollView's
    // live transform and is why Fit Width looked like a no-op or a jump.
    [_scrollView zoomToRect:zoomRect animated:YES];
}

- (IBAction)deleteNote:(id)sender {
    [_canvas endTextEditing];
    if (_document != nil && _document.session.deleteSelectedNote()) {
        [_document saveNotes];
        [self notesChanged:nil];
    }
}

- (void)clearTextSelection:(id)sender {
    [_canvas clearTextSelection];
}

- (void)clearSearchResults {
    _searchField.text = @"";
    if (_document != nil) {
        _document.session.clearSearch();
    }
    [_canvas setNeedsDisplay];
}

- (void)cancelSearch:(id)sender {
    [_searchField resignFirstResponder];
    [self clearSearchResults];
    [self setSearchExpanded:NO animated:sender != nil];
}

- (void)dismissHighlights:(id)sender {
    [_canvas clearTextSelection];
    if (_searchExpanded || (_document != nil && !_document.session.searchHits().empty())) {
        [self cancelSearch:sender];
    }
}

- (void)selectionChanged:(NSNotification *)notification {
    [self notesChanged:notification];
}

- (void)updateZoomCentering {
    const CGSize bounds = _scrollView.bounds.size;
    const CGSize zoomed = _scrollView.contentSize;
    const CGFloat extraX = std::max(0.0, (bounds.width - zoomed.width) * 0.5);
    const CGFloat extraY = std::max(0.0, (bounds.height - zoomed.height) * 0.5);
    const UIEdgeInsets next = UIEdgeInsetsMake(extraY, extraX, extraY, extraX);
    if (UIEdgeInsetsEqualToEdgeInsets(_scrollView.contentInset, next)) {
        return;
    }
    _scrollView.contentInset = next;
}

- (void)syncViewportZoom:(CGFloat)scale {
    if (_document == nil) {
        return;
    }
    _document.session.viewport().setScale(pager::ClampScale(scale));
    [_canvas updateVisibleRect];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _zoomContent;
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    [_canvas endTextEditing];
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    [self updateZoomCentering];
    [_canvas followVisibleRect];
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    [self updateZoomCentering];
    [self syncViewportZoom:scale];
    [self updatePageLabel];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (_document == nil) {
        return;
    }
    const CGFloat fit = [self fitWidthZoom];
    const CGFloat current = _scrollView.zoomScale;
    const CGFloat target = current < fit * 1.15 ? std::min(fit * 2.0, 8.0) : fit;
    const CGPoint point = [tap locationInView:_zoomContent];
    const CGSize visible = _scrollView.bounds.size;
    const CGSize rectSize = CGSizeMake(visible.width / target, visible.height / target);
    const CGRect zoomRect = CGRectMake(point.x - rectSize.width * 0.5, point.y - rectSize.height * 0.5,
                                       rectSize.width, rectSize.height);
    [_scrollView zoomToRect:zoomRect animated:YES];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView.isZooming) {
        [_canvas followVisibleRect];
        return;
    }
    [_canvas updateVisibleRect];
    [self updatePageLabel];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    [_canvas updateVisibleRect];
    [self updatePageLabel];
}

- (void)searchFieldEdited:(UITextField *)field {
    if (_document == nil || field.text.length > 0) {
        return;
    }
    _document.session.clearSearch();
    [_canvas setNeedsDisplay];
}

- (void)searchChanged:(UITextField *)field {
    if (_document == nil) {
        return;
    }
    NSString *query = field.text ?: @"";
    if (query.length == 0) {
        _document.session.clearSearch();
        [_canvas setNeedsDisplay];
        return;
    }
    _document.session.setSearchHits([_document.source findString:query]);
    const pager::TextSelection *hit = _document.session.currentSearchHit();
    if (hit != nullptr && !hit->quads.empty()) {
        [self scrollToPage:hit->quads.front().pageIndex userPoint:hit->quads.front().quad.v[0]];
    }
    [_canvas setNeedsDisplay];
}

- (void)stepSearchHit:(NSInteger)delta {
    if (_document == nil || !_document.session.advanceSearch(static_cast<int>(delta))) {
        return;
    }
    const pager::TextSelection *hit = _document.session.currentSearchHit();
    if (hit != nullptr && !hit->quads.empty()) {
        [self scrollToPage:hit->quads.front().pageIndex userPoint:hit->quads.front().quad.v[0]];
    }
    [_canvas setNeedsDisplay];
}

- (void)previousSearchHit:(id)sender {
    [self stepSearchHit:-1];
}

- (void)nextSearchHit:(id)sender {
    [self stepSearchHit:1];
}

- (void)scrollDocumentPoint:(pager::Point)point toViewportY:(CGFloat)viewportY {
    const CGFloat zoom = std::max(0.05, _scrollView.zoomScale);
    const CGPoint offset = CGPointMake(point.x * zoom - _scrollView.bounds.size.width * 0.5,
                                       point.y * zoom - viewportY);
    const pager::Point clamped = pager::ClampedOffset(
        pager::Point{offset.x, offset.y},
        pager::Size{_scrollView.contentSize.width, _scrollView.contentSize.height},
        pager::Size{_scrollView.bounds.size.width, _scrollView.bounds.size.height});
    [_scrollView setContentOffset:CGPointMake(clamped.x, clamped.y) animated:YES];
    [_canvas updateVisibleRect];
    [self updatePageLabel];
}

- (void)scrollToPage:(int)page userPoint:(pager::Point)point {
    const pager::PageGeometry *geometry = _document.session.viewport().geometry(page);
    if (geometry == nullptr) {
        return;
    }
    const pager::Point documentPoint =
        _document.session.viewport().layout().pageViewToDocument(page, pager::UserToPageView(*geometry, point));
    [self scrollDocumentPoint:documentPoint toViewportY:64];
}

- (void)scrollToNote:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    [self scrollToPage:[info[@"page"] intValue] userPoint:pager::Point{[info[@"x"] doubleValue], [info[@"y"] doubleValue]}];
}

- (void)notesChanged:(NSNotification *)notification {
    [self refreshStyleBar];
    [_notesTable reloadData];
    [_outlineTable reloadData];
    const pager::AnnotationId selected = _document == nil ? pager::AnnotationId{} : _document.session.selectedNote();
    NSInteger row = NSNotFound;
    if (_document != nil) {
        const auto &notes = _document.session.notes().annotations();
        for (NSInteger index = 0; index < static_cast<NSInteger>(notes.size()); ++index) {
            if (notes[static_cast<std::size_t>(index)].id == selected) {
                row = index;
                break;
            }
        }
    }
    if (row == NSNotFound) {
        [_notesTable deselectRowAtIndexPath:_notesTable.indexPathForSelectedRow animated:NO];
    } else {
        [_notesTable selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0] animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
    [_canvas setNeedsDisplay];
}

- (void)undo:(id)sender {
    if (_document == nil || !_document.session.notes().canUndo()) {
        return;
    }
    _document.session.notes().undo();
    _document.session.sanitizeSelection();
    [_document saveNotes];
    [self notesChanged:nil];
}

- (void)redo:(id)sender {
    if (_document == nil || !_document.session.notes().canRedo()) {
        return;
    }
    _document.session.notes().redo();
    _document.session.sanitizeSelection();
    [_document saveNotes];
    [self notesChanged:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)flatten:(id)sender {
    if (_document == nil) {
        [self showAlert:@"Nothing to export" message:@"Open a PDF first."];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PagerFlattened.pdf"]];
    NSError *error = nil;
    if (![_document.source writeFlattenedSession:_document.session toURL:url error:&error]) {
        [self showAlert:@"Export failed" message:error.localizedDescription ?: @"The PDF could not be written."];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    UIButton *anchor = [sender isKindOfClass:[UIButton class]] ? (UIButton *)sender : _moreButton;
    [self anchorPopover:activity fromButton:anchor];
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)editTextNoteAtRow:(NSInteger)row {
    if (_document == nil || row < 0 || row >= static_cast<NSInteger>(_document.session.notes().annotations().size())) {
        return;
    }
    const pager::Annotation note = _document.session.notes().annotations()[static_cast<std::size_t>(row)];
    if (note.kind != pager::AnnotationKind::FreeText) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Edit note" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @(note.contents.c_str());
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak ViewerViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        ViewerViewController *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_document == nil) {
            return;
        }
        NSString *text = alert.textFields.firstObject.text ?: @"";
        pager::NoteDocument &notes = strongSelf->_document.session.notes();
        pager::Annotation updated = note;
        updated.contents = text.UTF8String;
        notes.remove(note.id);
        notes.add(updated);
        [strongSelf->_document saveNotes];
        [strongSelf notesChanged:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_document == nil) {
        return 0;
    }
    if (tableView.tag == 1) {
        return _document.flattenedOutline.count;
    }
    return static_cast<NSInteger>(_document.session.notes().annotations().size());
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.backgroundColor = UIColor.clearColor;
    }
    if (tableView.tag == 1) {
        NSDictionary *item = _document.flattenedOutline[static_cast<NSUInteger>(indexPath.row)];
        cell.textLabel.text = item[@"title"];
        cell.indentationLevel = [item[@"depth"] integerValue];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Page %d", [item[@"page"] intValue] + 1];
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        const pager::Annotation &note = _document.session.notes().annotations()[static_cast<std::size_t>(indexPath.row)];
        cell.textLabel.text = @(pager::AnnotationKindName(note.kind));
        NSString *page = [NSString stringWithFormat:@"Page %d", note.pageIndex + 1];
        cell.detailTextLabel.text = note.contents.empty() ? page : [NSString stringWithFormat:@"%@ · %@", page, @(note.contents.c_str())];
        cell.indentationLevel = 0;
        cell.accessoryType = note.kind == pager::AnnotationKind::FreeText ? UITableViewCellAccessoryDetailButton
                                                                         : UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.tag == 1) {
        NSDictionary *item = _document.flattenedOutline[static_cast<NSUInteger>(indexPath.row)];
        [self scrollToPage:[item[@"page"] intValue] userPoint:pager::Point{[item[@"x"] doubleValue], [item[@"y"] doubleValue]}];
    } else {
        const pager::Annotation &note = _document.session.notes().annotations()[static_cast<std::size_t>(indexPath.row)];
        _document.session.setSelectedNote(note.id);
        [_canvas setNeedsDisplay];
        [self scrollToPage:note.pageIndex userPoint:pager::Point{note.bounds.x, note.bounds.y}];
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    if (tableView.tag == 2) {
        [self editTextNoteAtRow:indexPath.row];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.tag == 2;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.tag != 2 || editingStyle != UITableViewCellEditingStyleDelete || _document == nil) {
        return;
    }
    const pager::AnnotationId identifier = _document.session.notes().annotations()[static_cast<std::size_t>(indexPath.row)].id;
    _document.session.notes().remove(identifier);
    if (_document.session.selectedNote() == identifier) {
        _document.session.setSelectedNote({});
    }
    [_document saveNotes];
    [self notesChanged:nil];
}

@end
