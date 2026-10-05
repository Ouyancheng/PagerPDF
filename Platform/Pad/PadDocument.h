#pragma once

#import "CanvasController.h"
#import "PDFKitPageSource.h"

#include "DocumentSession.hpp"

#import <UIKit/UIKit.h>

@interface PadDocument : UIDocument <PagerSessionProvider>

- (pager::DocumentSession &)session;
- (PDFKitPageSource *)source;
- (void)saveNotes;
- (NSArray<NSDictionary *> *)flattenedOutline;

@end
