#pragma once

#include "Annotation.hpp"

#include <vector>

namespace pager {

class NoteDocument {
public:
    const std::vector<Annotation>& annotations() const { return annotations_; }
    bool canUndo() const { return !undo_.empty(); }
    bool canRedo() const { return !redo_.empty(); }

    void undo();
    void redo();
    void replaceAll(std::vector<Annotation> annotations);

    AnnotationId add(Annotation annotation);
    bool remove(AnnotationId id);
    const Annotation* find(AnnotationId id) const;
    Annotation* findMutable(AnnotationId id);
    // Snapshot the current list so the next in-place edit (resize, style) can undo as one step.
    void snapshot();
    std::vector<Annotation> eraseNear(int pageIndex, const PageGeometry& page, Point pageViewPoint, double radius);

    std::uint64_t peekNextId() const { return nextId_; }

private:

    std::vector<Annotation> annotations_;
    std::vector<std::vector<Annotation>> undo_;
    std::vector<std::vector<Annotation>> redo_;
    std::uint64_t nextId_ = 1;
};

}  // namespace pager
