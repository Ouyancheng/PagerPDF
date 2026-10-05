#pragma once

#include "Annotation.hpp"
#include "DocumentSession.hpp"
#include "Geometry.hpp"
#include "PageRasterSource.hpp"
#include "TextModel.hpp"

#include <Foundation/Foundation.h>

#include <vector>

@interface PDFKitPageSource : NSObject

- (BOOL)openURL:(NSURL *)url password:(NSString *)password error:(NSError **)error;
- (BOOL)openData:(NSData *)data error:(NSError **)error;
- (pager::PageRasterSource *)rasterSource;
- (NSInteger)pageCount;
- (pager::PageGeometry)geometryAtIndex:(NSInteger)index;
- (pager::TextSelection)selectionOnPage:(NSInteger)page fromUser:(pager::Point)start toUser:(pager::Point)end;
- (pager::TextSelection)selectionForWordOnPage:(NSInteger)page atUser:(pager::Point)point;
- (std::vector<pager::TextSelection>)findString:(NSString *)query;
- (std::vector<pager::OutlineItem>)outlineItems;
- (pager::LinkHit)linkOnPage:(NSInteger)page atUser:(pager::Point)point;
- (std::vector<pager::Annotation>)importAnnotations;
- (BOOL)writeFlattenedSession:(const pager::DocumentSession &)session toURL:(NSURL *)url error:(NSError **)error;

@end
