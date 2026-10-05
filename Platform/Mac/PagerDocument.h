#pragma once

#import "CanvasController.h"
#import "PDFKitPageSource.h"

#include "DocumentSession.hpp"
#include "TextModel.hpp"

#import <Cocoa/Cocoa.h>

@interface PagerOutlineNode : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSInteger page;
@property(nonatomic) double x;
@property(nonatomic) double y;
@property(nonatomic, strong) NSArray<PagerOutlineNode *> *children;
@end

@interface PagerDocument : NSDocument <PagerSessionProvider>

- (pager::DocumentSession &)session;
- (PDFKitPageSource *)source;
- (NSArray<PagerOutlineNode *> *)outline;
// Debounced, off-main-thread archive write.
- (void)saveNotes;
- (void)flushNotesAndWait;
// Renders a flattened copy in the background; `completion` runs on the main queue.
- (void)exportAnnotatedPDFToURL:(NSURL *)url completion:(void (^)(BOOL success, NSError *error))completion;
// Thread-safe page thumbnail (+1 reference), drawn from a private document.
- (CGImageRef)copyThumbnailForPage:(NSInteger)page maxPixels:(CGFloat)maxPixels;

@end
