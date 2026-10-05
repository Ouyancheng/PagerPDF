#import "AppDelegate.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (getenv("PAGER_EXIT_AFTER_LAUNCH") != nullptr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            exit(0);
        });
    }
}

// AppKit asks this only when the app was launched or reactivated with nothing to open.
- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender {
    return NSClassFromString(@"XCTestCase") == nil && getenv("PAGER_EXIT_AFTER_LAUNCH") == nullptr;
}

// Like Preview: with nothing to show, offer the Open panel instead of an empty app.
- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    [NSDocumentController.sharedDocumentController openDocument:nil];
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

@end
