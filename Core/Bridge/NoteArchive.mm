#import "NoteArchive.h"

#import <CommonCrypto/CommonCrypto.h>

namespace {

NSString *StorageKey(NSURL *pdfURL) {
    NSString *path = pdfURL.URLByResolvingSymlinksInPath.path ?: pdfURL.path ?: @"";
    NSData *bytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, static_cast<CC_LONG>(bytes.length), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

// Geometry is stored as arrays of NSNumber so values round-trip at full double precision and
// never depend on string formatting or parsing. Archives written by older versions used
// strings like "{{x, y}, {w, h}}"; those are still accepted on read.

NSArray *RectArray(pager::Rect rect) {
    return @[@(rect.x), @(rect.y), @(rect.width), @(rect.height)];
}

NSArray *PointArray(pager::Point point) {
    return @[@(point.x), @(point.y)];
}

bool ParseRect(id value, pager::Rect *rect) {
    if (rect == nullptr) {
        return false;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        if (array.count < 4) {
            return false;
        }
        *rect = pager::Rect{[array[0] doubleValue], [array[1] doubleValue], [array[2] doubleValue],
                            [array[3] doubleValue]};
        return true;
    }
    if ([value isKindOfClass:[NSString class]]) {
        double x = 0;
        double y = 0;
        double width = 0;
        double height = 0;
        if (sscanf([(NSString *)value UTF8String], "{{%lf, %lf}, {%lf, %lf}}", &x, &y, &width, &height) != 4) {
            return false;
        }
        *rect = pager::Rect{x, y, width, height};
        return true;
    }
    return false;
}

bool ParsePoint(id value, pager::Point *point) {
    if (point == nullptr) {
        return false;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        if (array.count < 2) {
            return false;
        }
        *point = pager::Point{[array[0] doubleValue], [array[1] doubleValue]};
        return true;
    }
    if ([value isKindOfClass:[NSString class]]) {
        double x = 0;
        double y = 0;
        if (sscanf([(NSString *)value UTF8String], "{%lf, %lf}", &x, &y) != 2) {
            return false;
        }
        *point = pager::Point{x, y};
        return true;
    }
    return false;
}

NSArray *ColorArray(pager::Color color) {
    return @[@(color.r), @(color.g), @(color.b), @(color.a)];
}

pager::Color ColorFromArray(NSArray *values) {
    if (values.count < 3) {
        return {};
    }
    pager::Color color;
    color.r = [values[0] floatValue];
    color.g = [values[1] floatValue];
    color.b = [values[2] floatValue];
    color.a = values.count > 3 ? [values[3] floatValue] : 1;
    return color;
}

NSDictionary *DictionaryForAnnotation(const pager::Annotation &note) {
    NSMutableDictionary *dictionary = [@{
        @"type" : @(pager::AnnotationKindName(note.kind)),
        @"pageIndex" : @(note.pageIndex),
        @"bounds" : RectArray(note.bounds),
        @"color" : ColorArray(note.color),
        @"contents" : @(note.contents.c_str()),
        @"id" : @(note.id.value),
        @"lineWidth" : @(note.lineWidth),
        @"fontSize" : @(note.fontSize),
        @"opacity" : @(note.opacity),
        @"stableKey" : @(note.stableKey.c_str()),
    } mutableCopy];
    if (note.kind == pager::AnnotationKind::Line) {
        dictionary[@"startPoint"] = PointArray(note.lineStart);
        dictionary[@"endPoint"] = PointArray(note.lineEnd);
    }
    if (!note.quads.empty()) {
        NSMutableArray *points = [NSMutableArray array];
        for (const pager::Quad &quad : note.quads) {
            for (const pager::Point &point : quad.v) {
                [points addObject:PointArray(point)];
            }
        }
        dictionary[@"quadrilateralPoints"] = points;
    }
    if (note.kind == pager::AnnotationKind::Ink) {
        NSMutableArray *path = [NSMutableArray array];
        NSMutableArray *forces = [NSMutableArray array];
        NSMutableArray *altitudes = [NSMutableArray array];
        for (const pager::InkSample &sample : note.samples) {
            [path addObject:PointArray(pager::Point{sample.x, sample.y})];
            [forces addObject:@(sample.force)];
            [altitudes addObject:@(sample.altitude)];
        }
        dictionary[@"pointLists"] = @[path];
        dictionary[@"pagerPressure"] = @[forces];
        dictionary[@"pagerAltitudes"] = altitudes;
        dictionary[@"pressure"] = @(note.pressure);
    }
    return dictionary;
}

pager::Annotation AnnotationFromDictionary(NSDictionary *dictionary) {
    pager::Annotation note;
    pager::AnnotationKind kind = pager::AnnotationKind::Highlight;
    if (!pager::AnnotationKindFromName([dictionary[@"type"] UTF8String] ?: "", &kind)) {
        note.id.value = 0;
        return note;
    }
    note.kind = kind;
    note.pageIndex = [dictionary[@"pageIndex"] intValue];
    note.id.value = [dictionary[@"id"] unsignedLongLongValue];
    note.lineWidth = [dictionary[@"lineWidth"] floatValue];
    note.fontSize = dictionary[@"fontSize"] != nil ? [dictionary[@"fontSize"] floatValue] : 14;
    if (note.fontSize <= 0) {
        note.fontSize = 14;
    }
    note.opacity = dictionary[@"opacity"] != nil ? [dictionary[@"opacity"] floatValue] : 1;
    note.pressure = [dictionary[@"pressure"] boolValue];
    note.contents = [dictionary[@"contents"] UTF8String] ?: "";
    note.stableKey = [dictionary[@"stableKey"] UTF8String] ?: std::to_string(note.pageIndex);
    note.color = ColorFromArray(dictionary[@"color"]);
    ParseRect(dictionary[@"bounds"], &note.bounds);
    ParsePoint(dictionary[@"startPoint"], &note.lineStart);
    ParsePoint(dictionary[@"endPoint"], &note.lineEnd);
    NSArray *quadPoints = dictionary[@"quadrilateralPoints"];
    if ([quadPoints isKindOfClass:[NSArray class]]) {
        for (NSUInteger index = 0; index + 3 < quadPoints.count; index += 4) {
            pager::Quad quad;
            bool complete = true;
            for (int corner = 0; corner < 4; ++corner) {
                if (!ParsePoint(quadPoints[index + corner], &quad.v[corner])) {
                    complete = false;
                }
            }
            if (complete) {
                note.quads.push_back(quad);
            }
        }
    }
    NSArray *pointLists = dictionary[@"pointLists"];
    NSArray *forces = [dictionary[@"pagerPressure"] firstObject];
    NSArray *altitudes = dictionary[@"pagerAltitudes"];
    NSArray *path = [pointLists isKindOfClass:[NSArray class]] ? pointLists.firstObject : nil;
    if ([path isKindOfClass:[NSArray class]]) {
        for (NSUInteger index = 0; index < path.count; ++index) {
            pager::Point point;
            if (!ParsePoint(path[index], &point)) {
                continue;
            }
            pager::InkSample sample;
            sample.x = point.x;
            sample.y = point.y;
            sample.force = [forces isKindOfClass:[NSArray class]] && index < forces.count ? [forces[index] floatValue] : 1;
            sample.altitude = [altitudes isKindOfClass:[NSArray class]] && index < altitudes.count ? [altitudes[index] floatValue] : 0;
            note.samples.push_back(sample);
        }
    }
    return note;
}

NSData *BookmarkForURL(NSURL *pdfURL) {
    if (pdfURL == nil) {
        return nil;
    }
#if TARGET_OS_IPHONE
    NSURLBookmarkCreationOptions options = NSURLBookmarkCreationMinimalBookmark;
#else
    NSURLBookmarkCreationOptions options = NSURLBookmarkCreationWithSecurityScope;
#endif
    return [pdfURL bookmarkDataWithOptions:options includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
}

}  // namespace

@implementation PagerNoteArchive

+ (NSURL *)supportDirectory {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"PagerPDF/Notes" isDirectory:YES];
}

+ (NSURL *)sidecarURLForPDF:(NSURL *)pdfURL {
    if (pdfURL == nil) {
        return nil;
    }
    NSString *name = [pdfURL.lastPathComponent stringByAppendingString:@".notes"];
    return [[pdfURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:name];
}

+ (NSURL *)applicationSupportURLForPDF:(NSURL *)pdfURL {
    if (pdfURL == nil) {
        return nil;
    }
    return [[self supportDirectory] URLByAppendingPathComponent:[StorageKey(pdfURL) stringByAppendingPathExtension:@"plist"]];
}

+ (NSData *)plistDataForDocument:(const pager::NoteDocument &)notes bookmark:(NSData *)bookmark {
    NSMutableArray *entries = [NSMutableArray array];
    for (const pager::Annotation &note : notes.annotations()) {
        [entries addObject:DictionaryForAnnotation(note)];
    }
    NSMutableDictionary *root = [@{@"version" : @1, @"notes" : entries} mutableCopy];
    if (bookmark != nil) {
        root[@"bookmark"] = bookmark;
    }
    return [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
}

+ (BOOL)readDocument:(pager::NoteDocument &)notes fromPlist:(NSData *)data error:(NSError **)error {
    if (data == nil) {
        if (error != nil) {
            *error = [NSError errorWithDomain:@"PagerPDF" code:5 userInfo:@{NSLocalizedDescriptionKey : @"Notes data is missing."}];
        }
        return NO;
    }
    id root = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error];
    if (![root isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSArray *entries = root[@"notes"];
    std::vector<pager::Annotation> annotations;
    if ([entries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *entry in entries) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            pager::AnnotationKind kind = pager::AnnotationKind::Highlight;
            if (!pager::AnnotationKindFromName([entry[@"type"] UTF8String] ?: "", &kind)) {
                continue;
            }
            annotations.push_back(AnnotationFromDictionary(entry));
        }
    }
    notes.replaceAll(std::move(annotations));
    return YES;
}

+ (BOOL)saveDocument:(const pager::NoteDocument &)notes pdfURL:(NSURL *)pdfURL error:(NSError **)error {
    NSData *bookmark = BookmarkForURL(pdfURL);
    NSData *data = [self plistDataForDocument:notes bookmark:bookmark];
    if (data == nil) {
        if (error != nil) {
            *error = [NSError errorWithDomain:@"PagerPDF" code:6 userInfo:@{NSLocalizedDescriptionKey : @"Notes could not be encoded."}];
        }
        return NO;
    }
    NSURL *directory = [self supportDirectory];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *store = [self applicationSupportURLForPDF:pdfURL];
    if (![data writeToURL:store options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    NSURL *sidecar = [self sidecarURLForPDF:pdfURL];
    [data writeToURL:sidecar options:NSDataWritingAtomic error:nil];
    return YES;
}

+ (BOOL)loadDocument:(pager::NoteDocument &)notes pdfURL:(NSURL *)pdfURL error:(NSError **)error {
    NSURL *sidecar = [self sidecarURLForPDF:pdfURL];
    NSData *data = [NSData dataWithContentsOfURL:sidecar];
    if (data == nil) {
        data = [NSData dataWithContentsOfURL:[self applicationSupportURLForPDF:pdfURL]];
    }
    if (data == nil) {
        notes.replaceAll({});
        return YES;
    }
    return [self readDocument:notes fromPlist:data error:error];
}

@end
