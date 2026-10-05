#pragma once

#include "NoteDocument.hpp"

#include <Foundation/Foundation.h>

#include <vector>

@interface PagerNoteArchive : NSObject

+ (NSURL *)sidecarURLForPDF:(NSURL *)pdfURL;
+ (NSURL *)applicationSupportURLForPDF:(NSURL *)pdfURL;
+ (BOOL)saveDocument:(const pager::NoteDocument &)notes pdfURL:(NSURL *)pdfURL error:(NSError **)error;
// Thread-safe; takes a copy so the caller can keep editing while this encodes and writes.
+ (BOOL)saveAnnotations:(const std::vector<pager::Annotation> &)annotations pdfURL:(NSURL *)pdfURL error:(NSError **)error;
+ (BOOL)loadDocument:(pager::NoteDocument &)notes pdfURL:(NSURL *)pdfURL error:(NSError **)error;
+ (NSData *)plistDataForDocument:(const pager::NoteDocument &)notes bookmark:(NSData *)bookmark;
+ (NSData *)plistDataForAnnotations:(const std::vector<pager::Annotation> &)annotations bookmark:(NSData *)bookmark;
+ (BOOL)readDocument:(pager::NoteDocument &)notes fromPlist:(NSData *)data error:(NSError **)error;

@end
