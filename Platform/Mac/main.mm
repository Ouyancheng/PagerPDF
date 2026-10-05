#import "AppDelegate.h"

#include "Annotation.hpp"

#include <cstdlib>

namespace {

NSMenuItem *Add(NSMenu *menu, NSString *title, SEL action, NSString *key,
                NSEventModifierFlags modifiers = NSEventModifierFlagCommand, NSInteger tag = 0) {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key ?: @""];
    item.keyEquivalentModifierMask = modifiers;
    item.tag = tag;
    return item;
}

NSMenu *Submenu(NSMenu *bar, NSString *title) {
    NSMenuItem *item = [bar addItemWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    item.submenu = menu;
    return menu;
}

NSString *Key(unichar character) {
    return [NSString stringWithCharacters:&character length:1];
}

NSMenu *BuildMainMenu(void) {
    const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    const NSEventModifierFlags shiftCmd = cmd | NSEventModifierFlagShift;
    const NSEventModifierFlags optCmd = cmd | NSEventModifierFlagOption;
    const NSEventModifierFlags ctrlCmd = cmd | NSEventModifierFlagControl;
    NSMenu *bar = [[NSMenu alloc] init];

    NSMenu *app = Submenu(bar, @"PagerPDF");
    Add(app, @"About PagerPDF", @selector(orderFrontStandardAboutPanel:), nil);
    [app addItem:NSMenuItem.separatorItem];
    NSMenuItem *services = Add(app, @"Services", nil, nil);
    services.submenu = [[NSMenu alloc] initWithTitle:@"Services"];
    NSApp.servicesMenu = services.submenu;
    [app addItem:NSMenuItem.separatorItem];
    Add(app, @"Hide PagerPDF", @selector(hide:), @"h");
    Add(app, @"Hide Others", @selector(hideOtherApplications:), @"h", optCmd);
    Add(app, @"Show All", @selector(unhideAllApplications:), nil);
    [app addItem:NSMenuItem.separatorItem];
    Add(app, @"Quit PagerPDF", @selector(terminate:), @"q");

    NSMenu *file = Submenu(bar, @"File");
    Add(file, @"Open…", @selector(openDocument:), @"o");
    NSMenuItem *recent = Add(file, @"Open Recent", nil, nil);
    NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    // NSDocumentController fills a menu that contains a Clear Menu item.
    Add(recentMenu, @"Clear Menu", @selector(clearRecentDocuments:), nil);
    recent.submenu = recentMenu;
    [file addItem:NSMenuItem.separatorItem];
    Add(file, @"Close", @selector(performClose:), @"w");
    [file addItem:NSMenuItem.separatorItem];
    Add(file, @"Export as Annotated PDF…", @selector(exportAnnotatedPDF:), @"e", shiftCmd);
    [file addItem:NSMenuItem.separatorItem];
    Add(file, @"Print…", @selector(printDocument:), @"p");

    NSMenu *edit = Submenu(bar, @"Edit");
    Add(edit, @"Undo", @selector(undo:), @"z");
    Add(edit, @"Redo", @selector(redo:), @"z", shiftCmd);
    [edit addItem:NSMenuItem.separatorItem];
    Add(edit, @"Cut", @selector(cut:), @"x");
    Add(edit, @"Copy", @selector(copy:), @"c");
    Add(edit, @"Paste", @selector(paste:), @"v");
    // No key equivalent: Delete must keep working in text fields; the page handles the key.
    Add(edit, @"Delete", @selector(delete:), nil, 0);
    Add(edit, @"Select All", @selector(selectAll:), @"a");
    [edit addItem:NSMenuItem.separatorItem];
    NSMenu *find = [[NSMenu alloc] initWithTitle:@"Find"];
    Add(find, @"Find…", @selector(performFindPanelAction:), @"f");
    Add(find, @"Find Next", @selector(findNext:), @"g");
    Add(find, @"Find Previous", @selector(findPrevious:), @"g", shiftCmd);
    Add(find, @"Use Selection for Find", @selector(useSelectionForFind:), @"e");
    Add(edit, @"Find", nil, nil).submenu = find;

    NSMenu *view = Submenu(bar, @"View");
    Add(view, @"Show Sidebar", @selector(toggleSidebar:), @"s", ctrlCmd);
    Add(view, @"Thumbnails", @selector(showSidebarModeFromMenu:), @"1", optCmd, 0);
    Add(view, @"Table of Contents", @selector(showSidebarModeFromMenu:), @"2", optCmd, 1);
    Add(view, @"Notes", @selector(showSidebarModeFromMenu:), @"3", optCmd, 2);
    [view addItem:NSMenuItem.separatorItem];
    Add(view, @"Actual Size", @selector(zoomImageToActualSize:), @"0");
    Add(view, @"Zoom In", @selector(zoomIn:), @"+");
    NSMenuItem *zoomInAlias = Add(view, @"Zoom In", @selector(zoomIn:), @"=");
    zoomInAlias.hidden = YES;
    zoomInAlias.allowsKeyEquivalentWhenHidden = YES;
    Add(view, @"Zoom Out", @selector(zoomOut:), @"-");
    Add(view, @"Zoom to Fit Width", @selector(zoomToFitWidth:), @"9");
    Add(view, @"Zoom to Fit Page", @selector(zoomToFitPage:), @"8");
    [view addItem:NSMenuItem.separatorItem];
    Add(view, @"Enter Full Screen", @selector(toggleFullScreen:), @"f", ctrlCmd);

    NSMenu *go = Submenu(bar, @"Go");
    Add(go, @"Previous Page", @selector(previousPage:), Key(NSUpArrowFunctionKey), optCmd);
    Add(go, @"Next Page", @selector(nextPage:), Key(NSDownArrowFunctionKey), optCmd);
    Add(go, @"First Page", @selector(firstPage:), Key(NSHomeFunctionKey), optCmd);
    Add(go, @"Last Page", @selector(lastPage:), Key(NSEndFunctionKey), optCmd);
    [go addItem:NSMenuItem.separatorItem];
    Add(go, @"Go to Page…", @selector(goToPage:), @"g", optCmd);

    NSMenu *tools = Submenu(bar, @"Tools");
    const struct {
        NSString *title;
        pager::Tool tool;
        NSString *key;
    } toolItems[] = {
        {@"Select", pager::Tool::Scroll, @"1"},          {@"Text Selection", pager::Tool::SelectText, @"2"},
        {@"Highlight", pager::Tool::Highlight, @"3"},    {@"Underline", pager::Tool::Underline, @"4"},
        {@"Strikethrough", pager::Tool::StrikeOut, @"5"}, {@"Pen", pager::Tool::Pen, @"6"},
        {@"Marker", pager::Tool::Marker, @"7"},          {@"Eraser", pager::Tool::Eraser, @"8"},
        {@"Rectangle", pager::Tool::Square, @"9"},       {@"Oval", pager::Tool::Circle, @"0"},
        {@"Line", pager::Tool::Line, nil},               {@"Text Box", pager::Tool::FreeText, nil},
    };
    for (const auto &entry : toolItems) {
        Add(tools, entry.title, @selector(selectToolFromMenu:), entry.key, ctrlCmd, static_cast<NSInteger>(entry.tool));
    }
    [tools addItem:NSMenuItem.separatorItem];
    Add(tools, @"Highlight Selected Text", @selector(highlightSelection:), @"h", ctrlCmd);
    Add(tools, @"Underline Selected Text", @selector(underlineSelection:), @"u", ctrlCmd);
    Add(tools, @"Strike Through Selected Text", @selector(strikeSelection:), @"x", ctrlCmd);

    NSMenu *window = Submenu(bar, @"Window");
    Add(window, @"Minimize", @selector(performMiniaturize:), @"m");
    Add(window, @"Zoom", @selector(performZoom:), nil);
    [window addItem:NSMenuItem.separatorItem];
    Add(window, @"Bring All to Front", @selector(arrangeInFront:), nil);
    NSApp.windowsMenu = window;

    NSMenu *help = Submenu(bar, @"Help");
    Add(help, @"PagerPDF Help", @selector(showHelp:), @"?");
    NSApp.helpMenu = help;
    return bar;
}

}  // namespace

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [NSDocumentController sharedDocumentController];
        application.mainMenu = BuildMainMenu();
        [application activate];
        [application run];
        return 0;
    }
}
