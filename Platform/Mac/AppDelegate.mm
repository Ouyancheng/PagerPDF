#import "AppDelegate.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (getenv("PAGER_EXIT_AFTER_LAUNCH") != nullptr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            exit(0);
        });
    }
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender {
    return NO;
}

@end
