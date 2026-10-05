#include "NoteDocument.hpp"

#include "AnnotationGeometry.hpp"

#include <algorithm>
#include <utility>

namespace pager {
namespace {

constexpr std::size_t kUndoLimit = 200;

}  // namespace

std::ptrdiff_t NoteDocument::indexOf(AnnotationId id) const {
    for (std::size_t index = 0; index < annotations_.size(); ++index) {
        if (annotations_[index].id == id) {
            return static_cast<std::ptrdiff_t>(index);
        }
    }
    return -1;
}

void NoteDocument::touchPage(int pageIndex) { pageRevisions_[pageIndex] = ++clock_; }

void NoteDocument::markPageDirty(int pageIndex) { touchPage(pageIndex); }

std::uint64_t NoteDocument::pageRevision(int pageIndex) const {
    const auto found = pageRevisions_.find(pageIndex);
    const std::uint64_t page = found == pageRevisions_.end() ? 0 : found->second;
    return std::max(page, resetRevision_);
}

void NoteDocument::pushStep(Step step) {
    if (step.ops.empty()) {
        return;
    }
    undo_.push_back(std::move(step));
    if (undo_.size() > kUndoLimit) {
        undo_.erase(undo_.begin());
    }
    redo_.clear();
}

void NoteDocument::record(Op op) {
    if (groupDepth_ > 0) {
        openGroup_.ops.push_back(std::move(op));
        return;
    }
    Step step;
    step.ops.push_back(std::move(op));
    pushStep(std::move(step));
}

void NoteDocument::beginGroup() { ++groupDepth_; }

void NoteDocument::endGroup() {
    if (groupDepth_ == 0) {
        return;
    }
    if (--groupDepth_ == 0) {
        Step step = std::move(openGroup_);
        openGroup_ = {};
        pushStep(std::move(step));
    }
}

void NoteDocument::apply(const Op& op, bool forward) {
    const bool inserting = (op.kind == OpKind::Insert) == forward;
    if (op.kind == OpKind::Replace) {
        const Annotation& target = forward ? op.after : op.before;
        const Annotation& replaced = forward ? op.before : op.after;
        const std::ptrdiff_t index = indexOf(target.id);
        if (index >= 0) {
            annotations_[static_cast<std::size_t>(index)] = target;
        }
        touchPage(replaced.pageIndex);
        touchPage(target.pageIndex);
        return;
    }
    const Annotation& subject = op.kind == OpKind::Insert ? op.after : op.before;
    if (inserting) {
        const std::size_t index = std::min(op.index, annotations_.size());
        annotations_.insert(annotations_.begin() + static_cast<std::ptrdiff_t>(index), subject);
    } else {
        const std::ptrdiff_t index = indexOf(subject.id);
        if (index >= 0) {
            annotations_.erase(annotations_.begin() + index);
        }
    }
    touchPage(subject.pageIndex);
}

void NoteDocument::undo() {
    if (undo_.empty()) {
        return;
    }
    editing_.clear();
    Step step = std::move(undo_.back());
    undo_.pop_back();
    for (auto op = step.ops.rbegin(); op != step.ops.rend(); ++op) {
        apply(*op, false);
    }
    redo_.push_back(std::move(step));
}

void NoteDocument::redo() {
    if (redo_.empty()) {
        return;
    }
    editing_.clear();
    Step step = std::move(redo_.back());
    redo_.pop_back();
    for (const Op& op : step.ops) {
        apply(op, true);
    }
    undo_.push_back(std::move(step));
}

void NoteDocument::replaceAll(std::vector<Annotation> annotations) {
    annotations_ = std::move(annotations);
    undo_.clear();
    redo_.clear();
    editing_.clear();
    openGroup_ = {};
    groupDepth_ = 0;
    pageRevisions_.clear();
    resetRevision_ = ++clock_;
    nextId_ = 1;
    for (const Annotation& annotation : annotations_) {
        if (annotation.id.value >= nextId_) {
            nextId_ = annotation.id.value + 1;
        }
    }
    // Archives can carry missing or duplicate ids; every note must be addressable.
    std::unordered_map<std::uint64_t, bool> seen;
    for (Annotation& annotation : annotations_) {
        if (annotation.id.value == 0 || seen.count(annotation.id.value) != 0) {
            annotation.id.value = nextId_++;
        }
        seen[annotation.id.value] = true;
    }
}

AnnotationId NoteDocument::add(Annotation annotation) {
    if (annotation.id.value == 0 || indexOf(annotation.id) >= 0) {
        annotation.id.value = nextId_++;
    } else if (annotation.id.value >= nextId_) {
        nextId_ = annotation.id.value + 1;
    }
    const AnnotationId id = annotation.id;
    Op op;
    op.kind = OpKind::Insert;
    op.index = annotations_.size();
    op.after = annotation;
    touchPage(annotation.pageIndex);
    annotations_.push_back(std::move(annotation));
    record(std::move(op));
    return id;
}

bool NoteDocument::remove(AnnotationId id) {
    const std::ptrdiff_t index = indexOf(id);
    if (index < 0) {
        return false;
    }
    Op op;
    op.kind = OpKind::Remove;
    op.index = static_cast<std::size_t>(index);
    op.before = std::move(annotations_[static_cast<std::size_t>(index)]);
    annotations_.erase(annotations_.begin() + index);
    editing_.erase(id.value);
    touchPage(op.before.pageIndex);
    record(std::move(op));
    return true;
}

const Annotation* NoteDocument::find(AnnotationId id) const {
    const std::ptrdiff_t index = indexOf(id);
    return index < 0 ? nullptr : &annotations_[static_cast<std::size_t>(index)];
}

Annotation* NoteDocument::findMutable(AnnotationId id) {
    const std::ptrdiff_t index = indexOf(id);
    return index < 0 ? nullptr : &annotations_[static_cast<std::size_t>(index)];
}

bool NoteDocument::update(AnnotationId id, const std::function<void(Annotation&)>& mutate) {
    Annotation* note = findMutable(id);
    if (note == nullptr) {
        return false;
    }
    Annotation before = *note;
    mutate(*note);
    note->id = id;
    if (SameContent(before, *note)) {
        return false;
    }
    Op op;
    op.kind = OpKind::Replace;
    op.before = std::move(before);
    op.after = *note;
    touchPage(op.before.pageIndex);
    touchPage(op.after.pageIndex);
    record(std::move(op));
    return true;
}

void NoteDocument::beginEdit(AnnotationId id) {
    const Annotation* note = find(id);
    if (note == nullptr || editing_.count(id.value) != 0) {
        return;
    }
    editing_.emplace(id.value, *note);
}

bool NoteDocument::endEdit(AnnotationId id, bool mergeIntoAdd) {
    const auto found = editing_.find(id.value);
    if (found == editing_.end()) {
        return false;
    }
    Annotation before = std::move(found->second);
    editing_.erase(found);
    const Annotation* note = find(id);
    if (note == nullptr) {
        return false;
    }
    touchPage(before.pageIndex);
    touchPage(note->pageIndex);
    if (SameContent(before, *note)) {
        return false;
    }
    if (mergeIntoAdd && groupDepth_ == 0 && !undo_.empty() && undo_.back().ops.size() == 1) {
        Op& last = undo_.back().ops.front();
        if (last.kind == OpKind::Insert && last.after.id == id) {
            last.after = *note;
            redo_.clear();
            return true;
        }
    }
    Op op;
    op.kind = OpKind::Replace;
    op.before = std::move(before);
    op.after = *note;
    record(std::move(op));
    return true;
}

void NoteDocument::discardAdd(AnnotationId id) {
    editing_.erase(id.value);
    if (groupDepth_ == 0 && !undo_.empty() && undo_.back().ops.size() == 1) {
        const Op& last = undo_.back().ops.front();
        if (last.kind == OpKind::Insert && last.after.id == id) {
            undo_.pop_back();
            const std::ptrdiff_t index = indexOf(id);
            if (index >= 0) {
                touchPage(annotations_[static_cast<std::size_t>(index)].pageIndex);
                annotations_.erase(annotations_.begin() + index);
            }
            return;
        }
    }
    remove(id);
}

std::vector<Annotation> NoteDocument::eraseAlong(int pageIndex, const PageGeometry& page, Point from, Point to,
                                                 double radius) {
    std::vector<Annotation> spawned;
    beginGroup();
    for (std::size_t index = 0; index < annotations_.size();) {
        const Annotation& annotation = annotations_[index];
        if (annotation.kind != AnnotationKind::Ink || annotation.pageIndex != pageIndex) {
            ++index;
            continue;
        }
        std::vector<Annotation> pieces;
        if (!EraseInkAlong(annotation, page, from, to, radius, &pieces)) {
            ++index;
            continue;
        }
        Op removal;
        removal.kind = OpKind::Remove;
        removal.index = index;
        removal.before = std::move(annotations_[index]);
        annotations_.erase(annotations_.begin() + static_cast<std::ptrdiff_t>(index));
        editing_.erase(removal.before.id.value);
        touchPage(pageIndex);
        record(std::move(removal));
        // Pieces take the original's place so z-order is unchanged.
        for (Annotation& piece : pieces) {
            piece.id.value = nextId_++;
            Op insert;
            insert.kind = OpKind::Insert;
            insert.index = index;
            insert.after = piece;
            annotations_.insert(annotations_.begin() + static_cast<std::ptrdiff_t>(index), piece);
            record(std::move(insert));
            spawned.push_back(std::move(piece));
            ++index;
        }
    }
    endGroup();
    return spawned;
}

std::vector<Annotation> NoteDocument::eraseNear(int pageIndex, const PageGeometry& page, Point pageViewPoint,
                                                double radius) {
    return eraseAlong(pageIndex, page, pageViewPoint, pageViewPoint, radius);
}

}  // namespace pager
