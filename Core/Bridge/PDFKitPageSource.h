#pragma once

#include "Annotation.hpp"
#include "DocumentSession.hpp"
#include "Geometry.hpp"
#include "PageRasterSource.hpp"
#include "TextModel.hpp"

#include <Foundation/Foundation.h>

#include <vector>

// Everything except rasterSource, writeFlattenedNotes and findString:completion: is
// main-thread API. Rasterization and export use private PDFDocument instances, so a slow
// page render never blocks text selection or link taps.
@interface PDFKitPageSource : NSObject

- (BOOL)openURL:(NSURL *)url password:(NSString *)password error:(NSError **)error;
- (BOOL)openData:(NSData *)data error:(NSError **)error;
- (pager::PageRasterSource *)rasterSource;
- (NSInteger)pageCount;
- (pager::PageGeometry)geometryAtIndex:(NSInteger)index;
- (pager::TextSelection)selectionOnPage:(NSInteger)page fromUser:(pager::Point)start toUser:(pager::Point)end;
- (pager::TextSelection)selectionForWordOnPage:(NSInteger)page atUser:(pager::Point)point;
- (std::vector<pager::TextSelection>)findString:(NSString *)query;
// Searches on a background queue; `completion` runs on the main queue unless a newer search
// (or cancelSearch) superseded this one.
- (void)findString:(NSString *)query completion:(void (^)(std::vector<pager::TextSelection> hits))completion;
- (void)cancelSearch;
- (std::vector<pager::OutlineItem>)outlineItems;
- (pager::LinkHit)linkOnPage:(NSInteger)page atUser:(pager::Point)point;
- (std::vector<pager::Annotation>)importAnnotations;
// Thread-safe: renders from a private document instance.
- (BOOL)writeFlattenedNotes:(const std::vector<pager::Annotation> &)notes toURL:(NSURL *)url error:(NSError **)error;
- (BOOL)writeFlattenedSession:(const pager::DocumentSession &)session toURL:(NSURL *)url error:(NSError **)error;

@end
