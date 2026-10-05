#include "OverlayRenderer.h"

#include "AnnotationGeometry.hpp"

#include <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <initializer_list>
#include <vector>

namespace pager {
namespace {

CGColorSpaceRef SRGB() {
    static CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return space;
}

CGPoint ToCG(Point point) { return CGPointMake(point.x, point.y); }

CGRect ToCG(const Rect &rect) { return CGRectMake(rect.x, rect.y, rect.width, rect.height); }

void SetFill(CGContextRef context, Color color, float alphaScale) {
    CGContextSetRGBFillColor(context, color.r, color.g, color.b, color.a * alphaScale);
}

void SetStroke(CGContextRef context, Color color) {
    CGContextSetRGBStrokeColor(context, color.r, color.g, color.b, color.a == 0 ? 1 : color.a);
}

std::uint64_t Mix(std::uint64_t hash, std::uint64_t value) {
    hash ^= value + 0x9E3779B97F4A7C15ull + (hash << 6) + (hash >> 2);
    return hash;
}

std::uint64_t Bits(double value) {
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

std::uint64_t InkFingerprint(const PageGeometry &page, const Annotation &note) {
    std::uint64_t hash = Mix(0, static_cast<std::uint64_t>(note.samples.size()));
    hash = Mix(hash, Bits(note.lineWidth));
    hash = Mix(hash, (note.pressure ? 1u : 0u) | (note.cutStart ? 2u : 0u) | (note.cutEnd ? 4u : 0u));
    hash = Mix(hash, static_cast<std::uint64_t>(page.rotation));
    for (const std::size_t index : {std::size_t{0}, note.samples.size() / 2, note.samples.size() - 1}) {
        if (index < note.samples.size()) {
            hash = Mix(hash, Bits(note.samples[index].x));
            hash = Mix(hash, Bits(note.samples[index].y));
            hash = Mix(hash, Bits(note.samples[index].force));
        }
    }
    return hash;
}

CGRect PageViewRect(const PageGeometry &page, const Rect &user) {
    const Point a = UserToPageView(page, Point{user.x, user.y});
    const Point b = UserToPageView(page, Point{user.x + user.width, user.y + user.height});
    return ToCG(BoundsOfPoints(a, b));
}

void StrokeSegment(CGContextRef context, Point a, Point b, float width) {
    CGContextSetLineWidth(context, std::max(1.0f, width));
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, a.x, a.y);
    CGContextAddLineToPoint(context, b.x, b.y);
    CGContextStrokePath(context);
}

void DrawQuads(CGContextRef context, const PageGeometry &page, const Annotation &note) {
    if (note.kind == AnnotationKind::Highlight) {
        // Notes composite over the page raster, so multiply is not available. A translucent
        // normal fill keeps the text readable the way Skim/Preview highlights do. One path
        // for every line so overlapping line boxes do not double the alpha.
        const float alpha = note.color.a > 0.01f && note.color.a < 0.85f ? 1 : 0.4f;
        SetFill(context, note.color, alpha);
        CGContextBeginPath(context);
        for (const Quad &quad : note.quads) {
            CGContextMoveToPoint(context, UserToPageView(page, quad.v[0]).x, UserToPageView(page, quad.v[0]).y);
            for (int corner = 1; corner < 4; ++corner) {
                const Point point = UserToPageView(page, quad.v[corner]);
                CGContextAddLineToPoint(context, point.x, point.y);
            }
            CGContextClosePath(context);
        }
        CGContextFillPath(context);
        return;
    }
    SetStroke(context, note.color);
    CGContextSetLineCap(context, kCGLineCapButt);
    const float width = note.lineWidth > 0 ? note.lineWidth : 1.5f;
    for (const Quad &quad : note.quads) {
        if (note.kind == AnnotationKind::Underline) {
            StrokeSegment(context, UserToPageView(page, quad.v[0]), UserToPageView(page, quad.v[1]), width);
        } else {
            const Point midA{(quad.v[0].x + quad.v[3].x) * 0.5, (quad.v[0].y + quad.v[3].y) * 0.5};
            const Point midB{(quad.v[1].x + quad.v[2].x) * 0.5, (quad.v[1].y + quad.v[2].y) * 0.5};
            StrokeSegment(context, UserToPageView(page, midA), UserToPageView(page, midB), width);
        }
    }
}

void DrawText(CGContextRef context, const Annotation &note, CGRect rect) {
    CFStringRef text = CFStringCreateWithCString(kCFAllocatorDefault, note.contents.c_str(), kCFStringEncodingUTF8);
    if (text == nullptr) {
        return;
    }
    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    // The CTM is y-down; CoreText lays out y-up.
    CGContextTranslateCTM(context, rect.origin.x, CGRectGetMaxY(rect));
    CGContextScaleCTM(context, 1, -1);
    const CGFloat size = std::max(8.0f, note.fontSize > 0 ? note.fontSize : 14);
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), size, nullptr);
    const CGFloat components[] = {note.color.r, note.color.g, note.color.b, note.color.a == 0 ? 1 : note.color.a};
    CGColorRef color = CGColorCreate(SRGB(), components);
    const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void *values[] = {font, color};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, text, attributes);
    CTFramesetterRef setter = CTFramesetterCreateWithAttributedString(attributed);
    const CGRect textRect = CGRectInset(CGRectMake(0, 0, rect.size.width, rect.size.height), 6, 4);
    if (textRect.size.width > 0 && textRect.size.height > 0) {
        CGPathRef path = CGPathCreateWithRect(textRect, nullptr);
        CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nullptr);
        CTFrameDraw(frame, context);
        CFRelease(frame);
        CGPathRelease(path);
    }
    CFRelease(setter);
    CFRelease(attributed);
    CFRelease(attributes);
    CGColorRelease(color);
    CFRelease(font);
    CFRelease(text);
    CGContextRestoreGState(context);
}

void DrawShape(CGContextRef context, const PageGeometry &page, const Annotation &note, bool hideContents) {
    const CGRect rect = PageViewRect(page, note.bounds);
    SetStroke(context, note.color);
    CGContextSetLineWidth(context, std::max(1.0f, note.lineWidth));
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    if (note.kind == AnnotationKind::Circle) {
        CGContextStrokeEllipseInRect(context, rect);
    } else if (note.kind == AnnotationKind::Line) {
        StrokeSegment(context, UserToPageView(page, note.lineStart), UserToPageView(page, note.lineEnd), note.lineWidth);
    } else if (note.kind == AnnotationKind::FreeText) {
        CGContextSetRGBFillColor(context, 1, 1, 1, 0.92);
        CGContextFillRect(context, rect);
        CGContextSetLineWidth(context, 1);
        CGContextStrokeRect(context, rect);
        if (!hideContents && !note.contents.empty()) {
            DrawText(context, note, rect);
        }
    } else {
        SetFill(context, note.color, 0.15f);
        CGContextFillRect(context, rect);
        CGContextStrokeRect(context, rect);
    }
}

void FillInk(CGContextRef context, CGPathRef path, Color color, float opacity) {
    if (path == nullptr) {
        return;
    }
    SetFill(context, color, opacity);
    CGContextBeginPath(context);
    CGContextAddPath(context, path);
    CGContextFillPath(context);
}

CGRect DocumentRectForPage(const DocumentSession &session, int pageIndex) {
    return ToCG(session.viewport().layout().pageFrame(pageIndex));
}

// Runs `draw` with the CTM moved into the page's page-view space.
template <typename Draw>
void InPage(CGContextRef context, const DocumentSession &session, int pageIndex, Draw draw) {
    const PageGeometry *page = session.viewport().geometry(pageIndex);
    if (page == nullptr) {
        return;
    }
    const CGRect frame = DocumentRectForPage(session, pageIndex);
    const double scale = session.viewport().layout().scale();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, frame.origin.x, frame.origin.y);
    CGContextScaleCTM(context, scale, scale);
    draw(*page);
    CGContextRestoreGState(context);
}

void FillDocumentQuad(CGContextRef context, const DocumentSession &session, int pageIndex, const Quad &quad) {
    InPage(context, session, pageIndex, [&](const PageGeometry &page) {
        CGContextBeginPath(context);
        const Point first = UserToPageView(page, quad.v[0]);
        CGContextMoveToPoint(context, first.x, first.y);
        for (int index = 1; index < 4; ++index) {
            const Point point = UserToPageView(page, quad.v[index]);
            CGContextAddLineToPoint(context, point.x, point.y);
        }
        CGContextClosePath(context);
        CGContextFillPath(context);
    });
}

void DrawSelectionChrome(CGContextRef context, const DocumentSession &session) {
    const Annotation *selected = session.selectedAnnotation();
    if (selected == nullptr) {
        return;
    }
    const PageGeometry *page = session.viewport().geometry(selected->pageIndex);
    if (page == nullptr) {
        return;
    }
    const CGRect frame = DocumentRectForPage(session, selected->pageIndex);
    CGRect rect = PageViewRect(*page, selected->bounds);
    rect = CGRectOffset(rect, frame.origin.x, frame.origin.y);
    rect = CGRectInset(rect, -4, -4);
    CGContextSaveGState(context);
    CGContextSetRGBStrokeColor(context, 0.15, 0.45, 0.95, 1);
    CGContextSetLineWidth(context, 1.5);
    const CGFloat dash[] = {5, 3};
    CGContextSetLineDash(context, 0, dash, 2);
    CGContextStrokeRect(context, rect);
    CGContextSetLineDash(context, 0, nullptr, 0);
    if (selected->kind == AnnotationKind::FreeText || selected->kind == AnnotationKind::Square ||
        selected->kind == AnnotationKind::Circle) {
        const CGFloat handle = 8;
        const CGPoint corners[] = {CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect)),
                                   CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect)),
                                   CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect)),
                                   CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))};
        CGContextSetRGBFillColor(context, 0.15, 0.45, 0.95, 1);
        for (const CGPoint corner : corners) {
            CGContextFillEllipseInRect(context, CGRectMake(corner.x - handle * 0.5, corner.y - handle * 0.5, handle, handle));
        }
    }
    CGContextRestoreGState(context);
}

}  // namespace

InkPathCache::~InkPathCache() { clear(); }

void InkPathCache::clear() {
    for (auto &entry : entries_) {
        CGPathRelease(entry.second.path);
    }
    entries_.clear();
}

CGPathRef InkPathCache::pathFor(const PageGeometry &page, const Annotation &note) {
    const std::uint64_t key = Mix(note.id.value, static_cast<std::uint64_t>(note.pageIndex));
    const std::uint64_t fingerprint = InkFingerprint(page, note);
    auto found = entries_.find(key);
    if (found != entries_.end() && found->second.fingerprint == fingerprint && found->second.path != nullptr) {
        return found->second.path;
    }
    if (entries_.size() > 4096) {
        clear();
        found = entries_.end();
    }
    CGPathRef path = CreateRibbonPath(
        BuildRibbon(note.samples, page, note.lineWidth <= 0 ? 2 : note.lineWidth, note.pressure, RibbonOptionsFor(note)));
    if (found != entries_.end()) {
        CGPathRelease(found->second.path);
        found->second = Entry{fingerprint, path};
    } else {
        entries_.emplace(key, Entry{fingerprint, path});
    }
    return path;
}

CGPathRef CreateRibbonPath(const std::vector<Triangle> &triangles) {
    if (triangles.empty()) {
        return nullptr;
    }
    CGMutablePathRef path = CGPathCreateMutable();
    for (const Triangle &triangle : triangles) {
        CGPathMoveToPoint(path, nullptr, triangle.a.x, triangle.a.y);
        CGPathAddLineToPoint(path, nullptr, triangle.b.x, triangle.b.y);
        CGPathAddLineToPoint(path, nullptr, triangle.c.x, triangle.c.y);
        CGPathCloseSubpath(path);
    }
    return path;
}

RibbonOptions RibbonOptionsFor(const Annotation &note) {
    RibbonOptions options;
    options.taperHead = !note.cutStart;
    options.taperTail = !note.cutEnd;
    return options;
}

void DrawInkSamplesInPage(CGContextRef context, const PageGeometry &page, const std::vector<InkSample> &samples,
                          Color color, float lineWidth, bool pressure, RibbonOptions options) {
    if (samples.empty()) {
        return;
    }
    CGPathRef path = CreateRibbonPath(BuildRibbon(samples, page, lineWidth <= 0 ? 2 : lineWidth, pressure, options));
    FillInk(context, path, color, 1);
    CGPathRelease(path);
}

void DrawAnnotationInPage(CGContextRef context, const PageGeometry &page, const Annotation &note,
                          AnnotationId hideContents, InkPathCache *cache) {
    CGContextSaveGState(context);
    if (!note.quads.empty() && (note.kind == AnnotationKind::Highlight || note.kind == AnnotationKind::Underline ||
                                note.kind == AnnotationKind::StrikeOut)) {
        DrawQuads(context, page, note);
    } else if (note.kind == AnnotationKind::Ink) {
        const float opacity = note.opacity == 0 ? 1 : note.opacity;
        if (cache != nullptr) {
            FillInk(context, cache->pathFor(page, note), note.color, opacity);
        } else {
            CGPathRef path = CreateRibbonPath(BuildRibbon(note.samples, page, note.lineWidth <= 0 ? 2 : note.lineWidth,
                                                          note.pressure, RibbonOptionsFor(note)));
            FillInk(context, path, note.color, opacity);
            CGPathRelease(path);
        }
    } else {
        DrawShape(context, page, note, hideContents.value != 0 && note.id == hideContents);
    }
    CGContextRestoreGState(context);
}

Annotation LiveStrokeStyle(const DocumentSession &session) {
    Annotation live;
    live.kind = AnnotationKind::Ink;
    live.pageIndex = session.penPage();
    const ToolStyle style = session.activeStyle();
    live.color = style.color;
    live.lineWidth = style.lineWidth > 0 ? style.lineWidth : (session.tool() == Tool::Marker ? 14 : 2.2f);
    live.pressure = session.tool() == Tool::Pen;
    live.opacity = 1;
    return live;
}

void DrawAnnotationInDocument(CGContextRef context, const DocumentSession &session, const Annotation &note,
                              AnnotationId hideContents) {
    InPage(context, session, note.pageIndex,
           [&](const PageGeometry &page) { DrawAnnotationInPage(context, page, note, hideContents); });
}

void DrawLivePen(CGContextRef context, const DocumentSession &session) {
    if (!session.pen().active()) {
        return;
    }
    const Annotation live = LiveStrokeStyle(session);
    // Committed and predicted samples form one ribbon at full strength: drawing the
    // prediction as a separate faint tail pinches the stroke where the two meet.
    InPage(context, session, live.pageIndex, [&](const PageGeometry &page) {
        DrawInkSamplesInPage(context, page, session.pen().display(), live.color, live.lineWidth, live.pressure);
    });
}

void DrawShapeDraft(CGContextRef context, const DocumentSession &session) {
    const ShapeDraft &draft = session.shapeDraft();
    if (!draft.active) {
        return;
    }
    const PageGeometry *page = session.viewport().geometry(draft.pageIndex);
    if (page == nullptr) {
        return;
    }
    Annotation note;
    note.kind = draft.kind;
    note.pageIndex = draft.pageIndex;
    note.color = draft.color;
    note.lineWidth = draft.lineWidth;
    note.lineStart = PageViewToUser(*page, draft.start);
    note.lineEnd = PageViewToUser(*page, draft.current);
    note.bounds = BoundsOfPoints(note.lineStart, note.lineEnd);
    DrawAnnotationInDocument(context, session, note);
}

void DrawPageLayer(CGContextRef context, CGRect dirty, const std::vector<CGRect> &pages,
                   const std::vector<PageTileBlit> &tiles) {
    CGContextSaveGState(context);
    FillCanvasColor(context);
    CGContextAddRect(context, dirty);
    for (const CGRect page : pages) {
        CGContextAddRect(context, page);
    }
    CGContextEOClip(context);
    CGContextFillRect(context, dirty);
    CGContextRestoreGState(context);
    for (const CGRect pageRect : pages) {
        if (!CGRectIntersectsRect(CGRectInset(pageRect, -2, -4), dirty)) {
            continue;
        }
        CGContextSetRGBFillColor(context, 0, 0, 0, 0.16);
        CGContextFillRect(context, CGRectInset(CGRectOffset(pageRect, 0, 2), -1, -1));
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, pageRect);
    }
    for (const PageTileBlit &tile : tiles) {
        if (tile.image == nullptr || !CGRectIntersectsRect(tile.frame, dirty)) {
            continue;
        }
        CGContextSaveGState(context);
        if (tile.pageClip.size.width > 0 && tile.pageClip.size.height > 0) {
            CGContextClipToRect(context, tile.pageClip);
        }
        // Nearest-neighbour is only lossless when the tile lands 1:1 on device pixels;
        // fallback tiles from another zoom are resampled.
        const CGSize device = CGContextConvertSizeToDeviceSpace(context, tile.frame.size);
        const double ratio = std::fabs(device.width) / std::max<size_t>(1, CGImageGetWidth(tile.image));
        CGContextSetInterpolationQuality(context, std::fabs(ratio - 1) < 0.01 ? kCGInterpolationNone
                                                                               : kCGInterpolationMedium);
        CGContextTranslateCTM(context, tile.frame.origin.x, tile.frame.origin.y + tile.frame.size.height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, tile.frame.size.width, tile.frame.size.height), tile.image);
        CGContextRestoreGState(context);
    }
}

void DrawSessionOverlay(CGContextRef context, CGRect dirty, const DocumentSession &session, bool drawLivePen,
                        AnnotationId hideContents) {
    for (const Annotation &note : session.notes().annotations()) {
        const PageGeometry *page = session.viewport().geometry(note.pageIndex);
        if (page == nullptr) {
            continue;
        }
        const CGRect frame = DocumentRectForPage(session, note.pageIndex);
        const CGRect bounds = CGRectOffset(ToCG(PageViewPaintBounds(*page, note)), frame.origin.x, frame.origin.y);
        if (CGRectIntersectsRect(bounds, dirty)) {
            DrawAnnotationInDocument(context, session, note, hideContents);
        }
    }
    const TextSelection &selection = session.selection();
    const Tool tool = session.tool();
    if (tool == Tool::Highlight || tool == Tool::Underline || tool == Tool::StrikeOut) {
        Annotation preview;
        preview.kind = tool == Tool::Highlight ? AnnotationKind::Highlight
                                               : (tool == Tool::Underline ? AnnotationKind::Underline : AnnotationKind::StrikeOut);
        preview.color = session.activeStyle().color;
        preview.lineWidth = session.activeStyle().lineWidth;
        for (const SelectionQuad &quad : selection.quads) {
            preview.pageIndex = quad.pageIndex;
            preview.quads = {quad.quad};
            DrawAnnotationInDocument(context, session, preview);
        }
    } else {
        CGContextSetRGBFillColor(context, 0.2, 0.45, 0.95, 0.28);
        for (const SelectionQuad &quad : selection.quads) {
            FillDocumentQuad(context, session, quad.pageIndex, quad.quad);
        }
    }
    const int searchCount = static_cast<int>(session.searchHits().size());
    for (int index = 0; index < searchCount; ++index) {
        const bool current = index == session.searchIndex();
        CGContextSetRGBFillColor(context, 1, current ? 0.55 : 0.85, 0.1, current ? 0.45 : 0.25);
        for (const SelectionQuad &quad : session.searchHits()[static_cast<std::size_t>(index)].quads) {
            FillDocumentQuad(context, session, quad.pageIndex, quad.quad);
        }
    }
    DrawShapeDraft(context, session);
    DrawSelectionChrome(context, session);
    if (drawLivePen) {
        DrawLivePen(context, session);
    }
}

}  // namespace pager
