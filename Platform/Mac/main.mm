#import "AppDelegate.h"

#include <cstdlib>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [NSDocumentController sharedDocumentController];

        NSMenu *menubar = [[NSMenu alloc] init];
        NSMenuItem *appItem = [[NSMenuItem alloc] init];
        [menubar addItem:appItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"PagerPDF"];
        [appMenu addItemWithTitle:@"Quit PagerPDF" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;

        NSMenuItem *fileItem = [[NSMenuItem alloc] init];
        [menubar addItem:fileItem];
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
        [fileMenu addItemWithTitle:@"Open…" action:@selector(openDocument:) keyEquivalent:@"o"];
        [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
        [fileMenu addItemWithTitle:@"Export Flattened PDF…" action:@selector(exportFlattened:) keyEquivalent:@"e"];
        fileItem.submenu = fileMenu;

        NSMenuItem *editItem = [[NSMenuItem alloc] init];
        [menubar addItem:editItem];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
        [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
        [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"Delete Note" action:@selector(deleteNote:) keyEquivalent:@"\b"];
        NSMenuItem *findItem = [editMenu addItemWithTitle:@"Find Next" action:@selector(findNext:) keyEquivalent:@"g"];
        findItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        [editMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"="];
        [editMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
        editItem.submenu = editMenu;

        application.mainMenu = menubar;
        [application activate];
        [application run];
        return 0;
    }
}
