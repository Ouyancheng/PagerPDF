#import "SceneDelegate.h"

#import "ViewerViewController.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    ViewerViewController *viewer = [[ViewerViewController alloc] init];
    self.window.rootViewController = viewer;
    [self.window makeKeyAndVisible];
    if (connectionOptions.URLContexts.count > 0) {
        [viewer openURL:connectionOptions.URLContexts.anyObject.URL];
    }
    if (getenv("PAGER_EXIT_AFTER_LAUNCH") != nullptr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            exit(0);
        });
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    NSURL *url = URLContexts.anyObject.URL;
    ViewerViewController *viewer = (ViewerViewController *)self.window.rootViewController;
    if (url != nil && [viewer isKindOfClass:[ViewerViewController class]]) {
        [viewer openURL:url];
    }
}

@end
