#include "OverlayRenderer.h"

#include "Ink.hpp"

#include <CoreText/CoreText.h>
#include <Foundation/Foundation.h>

#include <cmath>
#include <vector>

namespace pager {
namespace {

const PageGeometry *FindPage(const DocumentSession &session, int index) {
    return session.viewport().geometry(index);
}

Point ToDocument(const DocumentSession &session, int pageIndex, Point user) {
    const PageGeometry *page = FindPage(session, pageIndex);
    if (page == nullptr) {
        return {};
    }
    return session.viewport().layout().pageViewToDocument(pageIndex, UserToPageView(*page, user));
}

void SetFill(CGContextRef context, Color color, float alphaScale) {
    CGContextSetRGBFillColor(context, color.r, color.g, color.b, color.a * alphaScale);
}

void SetStroke(CGContextRef context, Color color) {
    CGContextSetRGBStrokeColor(context, color.r, color.g, color.b, color.a == 0 ? 1 : color.a);
}

void FillQuad(CGContextRef context, const DocumentSession &session, int pageIndex, const Quad &quad) {
    CGContextBeginPath(context);
    const Point first = ToDocument(session, pageIndex, quad.v[0]);
    CGContextMoveToPoint(context, first.x, first.y);
    for (int index = 1; index < 4; ++index) {
        const Point point = ToDocument(session, pageIndex, quad.v[index]);
        CGContextAddLineToPoint(context, point.x, point.y);
    }
    CGContextClosePath(context);
    CGContextFillPath(context);
}

void StrokeUserLine(CGContextRef context, const DocumentSession &session, int pageIndex, Point a, Point b, float width) {
    const Point start = ToDocument(session, pageIndex, a);
    const Point end = ToDocument(session, pageIndex, b);
    CGContextSetLineWidth(context, std::max(1.0f, width) * static_cast<float>(session.viewport().layout().scale()));
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, start.x, start.y);
    CGContextAddLineToPoint(context, end.x, end.y);
    CGContextStrokePath(context);
}

void DrawQuads(CGContextRef context, const DocumentSession &session, const Annotation &note) {
    for (const Quad &quad : note.quads) {
        if (note.kind == AnnotationKind::Highlight) {
            // Notes live on a clear overlay, so multiply would paint black. A translucent
            // normal fill keeps the text readable the way Skim/Preview highlights do.
            const float alpha = note.color.a > 0.01f && note.color.a < 0.85f ? 1 : 0.4f;
            SetFill(context, note.color, alpha);
            FillQuad(context, session, note.pageIndex, quad);
            continue;
        }
        SetStroke(context, note.color);
        const float width = note.lineWidth > 0 ? note.lineWidth : 1.5f;
        if (note.kind == AnnotationKind::Underline) {
            StrokeUserLine(context, session, note.pageIndex, quad.v[0], quad.v[1], width);
        } else {
            const Point midA{(quad.v[0].x + quad.v[3].x) * 0.5, (quad.v[0].y + quad.v[3].y) * 0.5};
            const Point midB{(quad.v[1].x + quad.v[2].x) * 0.5, (quad.v[1].y + quad.v[2].y) * 0.5};
            StrokeUserLine(context, session, note.pageIndex, midA, midB, width);
        }
    }
}

void DrawShape(CGContextRef context, const DocumentSession &session, const Annotation &note, bool hideContents = false) {
    const Point a = ToDocument(session, note.pageIndex, Point{note.bounds.x, note.bounds.y});
    const Point b = ToDocument(session, note.pageIndex, Point{note.bounds.x + note.bounds.width, note.bounds.y + note.bounds.height});
    const CGRect rect = CGRectMake(std::min(a.x, b.x), std::min(a.y, b.y), std::abs(a.x - b.x), std::abs(a.y - b.y));
    SetStroke(context, note.color);
    CGContextSetLineWidth(context, std::max(1.0f, note.lineWidth) * static_cast<float>(session.viewport().layout().scale()));
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    if (note.kind == AnnotationKind::Circle) {
        CGContextStrokeEllipseInRect(context, rect);
    } else if (note.kind == AnnotationKind::Line) {
        StrokeUserLine(context, session, note.pageIndex, note.lineStart, note.lineEnd, note.lineWidth);
    } else if (note.kind == AnnotationKind::FreeText) {
        CGContextSetRGBFillColor(context, 1, 1, 1, 0.92);
        CGContextFillRect(context, rect);
        SetStroke(context, note.color);
        CGContextSetLineWidth(context, 1);
        CGContextStrokeRect(context, rect);
        if (!hideContents && !note.contents.empty()) {
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, rect.origin.x, CGRectGetMaxY(rect));
            CGContextScaleCTM(context, 1, -1);
            const double scale = std::max(0.25, session.viewport().layout().scale());
            const CGFloat size = std::max(8.0f, note.fontSize > 0 ? note.fontSize : 14) * static_cast<CGFloat>(scale);
            NSString *text = @(note.contents.c_str());
            CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), size, nullptr);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            const CGFloat components[] = {note.color.r, note.color.g, note.color.b, note.color.a == 0 ? 1 : note.color.a};
            CGColorRef cgColor = CGColorCreate(colorSpace, components);
            const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
            const void *values[] = {font, cgColor};
            CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
            CFAttributedStringRef attributed =
                CFAttributedStringCreate(kCFAllocatorDefault, (__bridge CFStringRef)text, attrs);
            CTFramesetterRef setter = CTFramesetterCreateWithAttributedString(attributed);
            const CGRect textRect = CGRectInset(CGRectMake(0, 0, rect.size.width, rect.size.height), 6, 4);
            CGPathRef path = CGPathCreateWithRect(textRect, nullptr);
            CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nullptr);
            CTFrameDraw(frame, context);
            CFRelease(frame);
            CGPathRelease(path);
            CFRelease(setter);
            CFRelease(attributed);
            CFRelease(attrs);
            CGColorRelease(cgColor);
            CGColorSpaceRelease(colorSpace);
            CFRelease(font);
            CGContextRestoreGState(context);
        }
    } else {
        SetFill(context, note.color, 0.15f);
        CGContextFillRect(context, rect);
        CGContextStrokeRect(context, rect);
    }
}

void FillRibbon(CGContextRef context, const DocumentSession &session, int pageIndex, const std::vector<Triangle> &ribbon) {
    for (const Triangle &triangle : ribbon) {
        const Point a = session.viewport().layout().pageViewToDocument(pageIndex, triangle.a);
        const Point b = session.viewport().layout().pageViewToDocument(pageIndex, triangle.b);
        const Point c = session.viewport().layout().pageViewToDocument(pageIndex, triangle.c);
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, a.x, a.y);
        CGContextAddLineToPoint(context, b.x, b.y);
        CGContextAddLineToPoint(context, c.x, c.y);
        CGContextClosePath(context);
        CGContextFillPath(context);
    }
}

void DrawInk(CGContextRef context, const DocumentSession &session, const Annotation &note, const std::vector<InkSample> &samples) {
    const PageGeometry *page = FindPage(session, note.pageIndex);
    if (page == nullptr || samples.empty()) {
        return;
    }
    const float baseWidth = note.lineWidth <= 0 ? 2 : note.lineWidth;
    std::vector<InkSample> committed;
    std::vector<InkSample> predicted;
    committed.reserve(samples.size());
    for (const InkSample &sample : samples) {
        if (sample.predicted) {
            predicted.push_back(sample);
        } else {
            committed.push_back(sample);
        }
    }
    const float alpha = note.opacity == 0 ? 1 : note.opacity;
    if (!committed.empty()) {
        SetFill(context, note.color, alpha);
        FillRibbon(context, session, note.pageIndex, BuildRibbon(committed, *page, baseWidth, note.pressure));
    }
    if (!predicted.empty()) {
        std::vector<InkSample> tail;
        if (!committed.empty()) {
            tail.push_back(committed.back());
        }
        tail.insert(tail.end(), predicted.begin(), predicted.end());
        SetFill(context, note.color, alpha * 0.38f);
        FillRibbon(context, session, note.pageIndex, BuildRibbon(tail, *page, baseWidth, note.pressure));
    }
}

void DrawShapeDraft(CGContextRef context, const DocumentSession &session) {
    const ShapeDraft &draft = session.shapeDraft();
    if (!draft.active) {
        return;
    }
    const PageGeometry *page = FindPage(session, draft.pageIndex);
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
    DrawShape(context, session, note);
}

void DrawSelection(CGContextRef context, const DocumentSession &session) {
    if (session.selectedNote().value == 0) {
        return;
    }
    const Annotation *selected = nullptr;
    for (const Annotation &note : session.notes().annotations()) {
        if (note.id == session.selectedNote()) {
            selected = &note;
            break;
        }
    }
    if (selected == nullptr) {
        return;
    }
    const Point min = ToDocument(session, selected->pageIndex, Point{selected->bounds.x, selected->bounds.y});
    const Point max = ToDocument(session, selected->pageIndex,
                                 Point{selected->bounds.x + selected->bounds.width, selected->bounds.y + selected->bounds.height});
    CGRect rect = CGRectMake(std::min(min.x, max.x) - 4, std::min(min.y, max.y) - 4, std::abs(max.x - min.x) + 8,
                             std::abs(max.y - min.y) + 8);
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
}

void DrawAnnotation(CGContextRef context, const DocumentSession &session, const Annotation &note,
                    AnnotationId hideContents = {}) {
    if (!note.quads.empty() && (note.kind == AnnotationKind::Highlight || note.kind == AnnotationKind::Underline ||
                                note.kind == AnnotationKind::StrikeOut)) {
        DrawQuads(context, session, note);
        return;
    }
    if (note.kind == AnnotationKind::Ink) {
        DrawInk(context, session, note, note.samples);
        return;
    }
    DrawShape(context, session, note, note.id == hideContents);
}

bool IntersectsDirty(const DocumentSession &session, const Annotation &note, CGRect dirty) {
    const Point min = ToDocument(session, note.pageIndex, Point{note.bounds.x, note.bounds.y});
    const Point max = ToDocument(session, note.pageIndex,
                                 Point{note.bounds.x + note.bounds.width, note.bounds.y + note.bounds.height});
    const double slop =
        std::max(2.0, static_cast<double>(note.lineWidth) * session.viewport().layout().scale() + 2.0) +
        (note.kind == AnnotationKind::Ink ? 10.0 * session.viewport().layout().scale() : 0);
    const CGRect bounds =
        CGRectMake(std::min(min.x, max.x) - slop, std::min(min.y, max.y) - slop,
                   std::abs(max.x - min.x) + slop * 2, std::abs(max.y - min.y) + slop * 2);
    return CGRectIntersectsRect(bounds, dirty);
}

void DrawTile(CGContextRef context, CGRect frame, CGImageRef image) {
    if (image == nullptr) {
        return;
    }
    CGContextSaveGState(context);
    // Tiles are already rasterized at the display density. Extra interpolation
    // turns crisp glyphs into mush when the rect is a few pixels off.
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextTranslateCTM(context, frame.origin.x, frame.origin.y + frame.size.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, frame.size.width, frame.size.height), image);
    CGContextRestoreGState(context);
}

}  // namespace

void DrawLivePen(CGContextRef context, const DocumentSession &session) {
    if (!session.pen().active()) {
        return;
    }
    Annotation live;
    live.kind = AnnotationKind::Ink;
    live.pageIndex = session.penPage();
    const ToolStyle style = session.activeStyle();
    live.color = style.color;
    live.lineWidth = style.lineWidth > 0 ? style.lineWidth : (session.tool() == Tool::Marker ? 14 : 2.2f);
    live.pressure = session.tool() == Tool::Pen;
    live.opacity = 1;
    DrawInk(context, session, live, session.pen().display());
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
        if (!CGRectIntersectsRect(pageRect, dirty)) {
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
        DrawTile(context, tile.frame, tile.image);
        CGContextRestoreGState(context);
    }
}

void DrawPages(CGContextRef context, CGRect dirty, const DocumentSession &session, const TileImageLookup &images,
               const TileFallbackWalk &fallbacks) {
    std::vector<CGRect> pages;
    std::vector<PageTileBlit> tiles;
    for (const PageFrame &frame : session.viewport().layout().pages()) {
        pages.push_back(CGRectMake(frame.frame.x, frame.frame.y, frame.frame.width, frame.frame.height));
    }
    if (fallbacks) {
        fallbacks([&](int pageIndex, CGRect frame, CGImageRef image) {
            if (image == nullptr) {
                return;
            }
            const Rect page = session.viewport().layout().pageFrame(pageIndex);
            tiles.push_back(PageTileBlit{CGRectMake(page.x, page.y, page.width, page.height), frame, image});
        });
    }
    if (images) {
        for (const TileSlot &slot : session.viewport().visibleSlots()) {
            const CGRect frame = CGRectMake(slot.documentFrame.x, slot.documentFrame.y, slot.documentFrame.width,
                                            slot.documentFrame.height);
            const Rect page = session.viewport().layout().pageFrame(slot.key.page);
            tiles.push_back(PageTileBlit{CGRectMake(page.x, page.y, page.width, page.height), frame, images(slot.key)});
        }
    }
    DrawPageLayer(context, dirty, pages, tiles);
}

void DrawSessionOverlay(CGContextRef context, CGRect dirty, const DocumentSession &session, bool drawLivePen,
                        AnnotationId hideContents) {
    for (const Annotation &note : session.imported) {
        if (IntersectsDirty(session, note, dirty)) {
            DrawAnnotation(context, session, note, hideContents);
        }
    }
    for (const Annotation &note : session.notes().annotations()) {
        if (IntersectsDirty(session, note, dirty)) {
            DrawAnnotation(context, session, note, hideContents);
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
            DrawQuads(context, session, preview);
        }
    } else {
        CGContextSetRGBFillColor(context, 0.2, 0.45, 0.95, 0.28);
        for (const SelectionQuad &quad : selection.quads) {
            FillQuad(context, session, quad.pageIndex, quad.quad);
        }
    }
    const int searchCount = static_cast<int>(session.searchHits().size());
    for (int index = 0; index < searchCount; ++index) {
        const bool current = index == session.searchIndex();
        CGContextSetRGBFillColor(context, current ? 1 : 1, current ? 0.55 : 0.85, 0.1, current ? 0.45 : 0.25);
        for (const SelectionQuad &quad : session.searchHits()[static_cast<std::size_t>(index)].quads) {
            FillQuad(context, session, quad.pageIndex, quad.quad);
        }
    }
    DrawShapeDraft(context, session);
    DrawSelection(context, session);
    if (drawLivePen) {
        DrawLivePen(context, session);
    }
}

void DrawDocument(CGContextRef context, CGRect dirty, const DocumentSession &session, const TileImageLookup &images,
                  bool drawLivePen, const TileFallbackWalk &fallbacks) {
    DrawPages(context, dirty, session, images, fallbacks);
    DrawSessionOverlay(context, dirty, session, drawLivePen);
}

}  // namespace pager
