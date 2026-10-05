#pragma once

#include "Annotation.hpp"

#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>

namespace pager {

// Annotation list with operation-based undo. Each undo step stores only the annotations it
// touched, so history cost is proportional to the edit, not to the whole document.
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
    // In-place access. Wrap edits in beginEdit/endEdit (or use update) so they are undoable
    // and the affected page is redrawn.
    Annotation* findMutable(AnnotationId id);
    // Applies `mutate` as one undoable step; returns false if the note is missing or unchanged.
    bool update(AnnotationId id, const std::function<void(Annotation&)>& mutate);
    void beginEdit(AnnotationId id);
    // Records the edit opened by beginEdit if anything changed. With `mergeIntoAdd`, an edit
    // of the annotation added by the most recent step folds into that step (create + type
    // text undoes as one).
    bool endEdit(AnnotationId id, bool mergeIntoAdd = false);
    bool isEditing(AnnotationId id) const { return editing_.count(id.value) != 0; }
    // Removes an annotation; if the latest undo step is exactly its creation, that step is
    // dropped too (an abandoned empty text box leaves no history).
    void discardAdd(AnnotationId id);

    // Nested grouping: everything between the outermost begin/end undoes as one step.
    void beginGroup();
    void endGroup();

    // Erases ink under a capsule swept from `from` to `to` (page view). Returns the new pieces.
    std::vector<Annotation> eraseAlong(int pageIndex, const PageGeometry& page, Point from, Point to, double radius);
    std::vector<Annotation> eraseNear(int pageIndex, const PageGeometry& page, Point pageViewPoint, double radius);

    // Monotonic change counters. pageRevision changes whenever anything on that page does.
    std::uint64_t revision() const { return clock_; }
    std::uint64_t pageRevision(int pageIndex) const;
    void markPageDirty(int pageIndex);

    std::uint64_t peekNextId() const { return nextId_; }

private:
    enum class OpKind { Insert, Remove, Replace };
    struct Op {
        OpKind kind = OpKind::Insert;
        std::size_t index = 0;
        Annotation before;
        Annotation after;
    };
    struct Step {
        std::vector<Op> ops;
    };

    void record(Op op);
    void pushStep(Step step);
    void apply(const Op& op, bool forward);
    std::ptrdiff_t indexOf(AnnotationId id) const;
    void touchPage(int pageIndex);

    std::vector<Annotation> annotations_;
    std::vector<Step> undo_;
    std::vector<Step> redo_;
    int groupDepth_ = 0;
    Step openGroup_;
    std::unordered_map<std::uint64_t, Annotation> editing_;
    std::unordered_map<int, std::uint64_t> pageRevisions_;
    std::uint64_t resetRevision_ = 0;
    std::uint64_t clock_ = 0;
    std::uint64_t nextId_ = 1;
};

}  // namespace pager
