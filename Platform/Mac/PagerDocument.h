#pragma once

#import "PDFKitPageSource.h"

#include "DocumentSession.hpp"

#import <Cocoa/Cocoa.h>

@class PagerDocumentView;

@interface PagerDocument : NSDocument <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate>

- (pager::DocumentSession &)session;
- (PDFKitPageSource *)source;
- (void)notesDidChange;
- (void)syncNoteSelection;
- (IBAction)deleteNote:(id)sender;
- (IBAction)toggleSidebar:(id)sender;
- (void)scrollToPage:(int)page userPoint:(pager::Point)point;
- (void)commitZoomFactor:(double)factor anchorInDocument:(pager::Point)anchor;

@end
