#pragma once

#import "PagerDocument.h"

@interface PagerDocumentView : NSView

- (void)attachToDocument:(PagerDocument *)document;
- (void)detachViewport;
- (void)syncFrameAndTiles;
- (void)reloadTilesAfterScale;
- (void)updateVisibleRect;
- (void)acceptTile:(pager::TileImage)tile;

@end
