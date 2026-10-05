#pragma once

#import "PDFKitPageSource.h"

#include "DocumentSession.hpp"

#import <UIKit/UIKit.h>

@interface PadDocument : UIDocument

- (pager::DocumentSession &)session;
- (PDFKitPageSource *)source;
- (void)saveNotes;
- (NSArray<NSDictionary *> *)flattenedOutline;

@end
