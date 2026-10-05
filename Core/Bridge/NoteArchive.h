#pragma once

#include "NoteDocument.hpp"

#include <Foundation/Foundation.h>

@interface PagerNoteArchive : NSObject

+ (NSURL *)sidecarURLForPDF:(NSURL *)pdfURL;
+ (NSURL *)applicationSupportURLForPDF:(NSURL *)pdfURL;
+ (BOOL)saveDocument:(const pager::NoteDocument &)notes pdfURL:(NSURL *)pdfURL error:(NSError **)error;
+ (BOOL)loadDocument:(pager::NoteDocument &)notes pdfURL:(NSURL *)pdfURL error:(NSError **)error;
+ (NSData *)plistDataForDocument:(const pager::NoteDocument &)notes bookmark:(NSData *)bookmark;
+ (BOOL)readDocument:(pager::NoteDocument &)notes fromPlist:(NSData *)data error:(NSError **)error;

@end
