#pragma once

#include "Ink.hpp"
#include "NoteDocument.hpp"
#include "TextModel.hpp"
#include "Viewport.hpp"

namespace pager {

struct ShapeDraft {
    bool active = false;
    AnnotationKind kind = AnnotationKind::Line;
    int pageIndex = -1;
    Point start;
    Point current;
    Color color;
    float lineWidth = 1.5f;
};

struct ToolStyle {
    Color color;
    float lineWidth = 2.2f;
    float fontSize = 14;
};

ToolStyle DefaultStyleForTool(Tool tool);

class DocumentSession {
public:
    DocumentSession();
    Viewport& viewport() { return viewport_; }
    const Viewport& viewport() const { return viewport_; }
    NoteDocument& notes() { return notes_; }
    const NoteDocument& notes() const { return notes_; }

    void setTool(Tool tool) { tool_ = tool; }
    Tool tool() const { return tool_; }
    void setToolStyle(Tool tool, ToolStyle style);
    ToolStyle toolStyle(Tool tool) const;
    ToolStyle activeStyle() const { return toolStyle(tool_); }

    void setSelection(TextSelection selection) { selection_ = std::move(selection); }
    const TextSelection& selection() const { return selection_; }
    void clearSelection() { selection_ = {}; }

    void setSearchHits(std::vector<TextSelection> hits);
    void clearSearch() { setSearchHits({}); }
    const std::vector<TextSelection>& searchHits() const { return searchHits_; }
    int searchIndex() const { return searchIndex_; }
    const TextSelection* currentSearchHit() const;
    bool advanceSearch(int delta);

    StrokeBuilder& pen() { return pen_; }
    const StrokeBuilder& pen() const { return pen_; }
    void setPenPage(int pageIndex) { penPage_ = pageIndex; }
    int penPage() const { return penPage_; }

    void setShapeDraft(AnnotationKind kind, int pageIndex, Point start, Point current);
    void clearShapeDraft();
    const ShapeDraft& shapeDraft() const { return shapeDraft_; }

    void setSelectedNote(AnnotationId id) { selectedNote_ = id; }
    AnnotationId selectedNote() const { return selectedNote_; }
    const Annotation* selectedAnnotation() const;
    Annotation* selectedAnnotationMutable();
    bool selectNoteAt(Point documentPoint);
    bool deleteSelectedNote();
    // Drops the selection if it points at an annotation that no longer exists (e.g. after undo).
    void sanitizeSelection();

    std::vector<Annotation> imported;

    AnnotationId addAnnotation(Annotation annotation);
    AnnotationId addMarkup(AnnotationKind kind, const TextSelection& selection, Color color);
    AnnotationId addShape(AnnotationKind kind, int pageIndex, const PageGeometry& page, Point pageViewA,
                          Point pageViewB, Color color, float lineWidth);
    AnnotationId addTextNote(int pageIndex, const PageGeometry& page, Point pageView, const std::string& text,
                             Color color, float fontSize = 0);
    AnnotationId commitPen(int pageIndex, const PageGeometry& page, Color color, float baseWidth, bool pressure);
    void eraseAt(int pageIndex, const PageGeometry& page, Point pageView, double radius);

private:
    Viewport viewport_;
    NoteDocument notes_;
    Tool tool_ = Tool::Scroll;
    TextSelection selection_;
    std::vector<TextSelection> searchHits_;
    int searchIndex_ = -1;
    StrokeBuilder pen_;
    int penPage_ = -1;
    ShapeDraft shapeDraft_;
    AnnotationId selectedNote_;
    ToolStyle styles_[16] = {};
};

}  // namespace pager
