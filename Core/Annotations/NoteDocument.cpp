#include "NoteDocument.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace pager {
namespace {

double Distance(Point a, Point b) {
    const double dx = a.x - b.x;
    const double dy = a.y - b.y;
    return std::sqrt(dx * dx + dy * dy);
}

}  // namespace

void NoteDocument::snapshot() {
    undo_.push_back(annotations_);
    if (undo_.size() > 100) {
        undo_.erase(undo_.begin());
    }
    redo_.clear();
}

void NoteDocument::undo() {
    if (undo_.empty()) {
        return;
    }
    redo_.push_back(annotations_);
    annotations_ = std::move(undo_.back());
    undo_.pop_back();
}

void NoteDocument::redo() {
    if (redo_.empty()) {
        return;
    }
    undo_.push_back(annotations_);
    annotations_ = std::move(redo_.back());
    redo_.pop_back();
}

void NoteDocument::replaceAll(std::vector<Annotation> annotations) {
    annotations_ = std::move(annotations);
    undo_.clear();
    redo_.clear();
    nextId_ = 1;
    for (const Annotation& annotation : annotations_) {
        if (annotation.id.value >= nextId_) {
            nextId_ = annotation.id.value + 1;
        }
    }
}

AnnotationId NoteDocument::add(Annotation annotation) {
    snapshot();
    if (annotation.id.value == 0) {
        annotation.id.value = nextId_++;
    } else if (annotation.id.value >= nextId_) {
        nextId_ = annotation.id.value + 1;
    }
    const AnnotationId id = annotation.id;
    annotations_.push_back(std::move(annotation));
    return id;
}

bool NoteDocument::remove(AnnotationId id) {
    const auto found = std::find_if(annotations_.begin(), annotations_.end(),
                                    [id](const Annotation& annotation) { return annotation.id == id; });
    if (found == annotations_.end()) {
        return false;
    }
    snapshot();
    annotations_.erase(found);
    return true;
}

const Annotation* NoteDocument::find(AnnotationId id) const {
    const auto found = std::find_if(annotations_.begin(), annotations_.end(),
                                    [id](const Annotation& annotation) { return annotation.id == id; });
    return found == annotations_.end() ? nullptr : &*found;
}

Annotation* NoteDocument::findMutable(AnnotationId id) {
    const auto found = std::find_if(annotations_.begin(), annotations_.end(),
                                    [id](const Annotation& annotation) { return annotation.id == id; });
    return found == annotations_.end() ? nullptr : &*found;
}

std::vector<Annotation> NoteDocument::eraseNear(int pageIndex, const PageGeometry& page, Point pageViewPoint,
                                                double radius) {
    std::vector<Annotation> next;
    std::vector<Annotation> spawned;
    bool changed = false;
    next.reserve(annotations_.size());
    for (const Annotation& annotation : annotations_) {
        if (annotation.kind != AnnotationKind::Ink || annotation.pageIndex != pageIndex) {
            next.push_back(annotation);
            continue;
        }
        std::vector<InkSample> run;
        int removed = 0;
        std::vector<Annotation> pieces;
        auto flush = [&]() {
            if (run.size() < 2) {
                run.clear();
                return;
            }
            Annotation piece = annotation;
            piece.id.value = 0;
            piece.samples = run;
            double minX = run[0].x;
            double minY = run[0].y;
            double maxX = run[0].x;
            double maxY = run[0].y;
            for (const InkSample& sample : run) {
                minX = std::min(minX, sample.x);
                minY = std::min(minY, sample.y);
                maxX = std::max(maxX, sample.x);
                maxY = std::max(maxY, sample.y);
            }
            piece.bounds = Rect{minX, minY, maxX - minX, maxY - minY};
            pieces.push_back(std::move(piece));
            run.clear();
        };
        for (const InkSample& sample : annotation.samples) {
            if (sample.predicted) {
                continue;
            }
            const Point view = UserToPageView(page, Point{sample.x, sample.y});
            if (Distance(view, pageViewPoint) <= radius) {
                ++removed;
                flush();
                continue;
            }
            run.push_back(sample);
        }
        flush();
        if (removed == 0) {
            next.push_back(annotation);
            continue;
        }
        changed = true;
        for (Annotation& piece : pieces) {
            piece.id.value = nextId_++;
            spawned.push_back(piece);
            next.push_back(std::move(piece));
        }
    }
    if (!changed) {
        return {};
    }
    snapshot();
    annotations_ = std::move(next);
    return spawned;
}

}  // namespace pager
