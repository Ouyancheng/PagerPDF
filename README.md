# PagerPDF

A native PDF reader and annotator for **macOS** and **iPadOS**. Pages stay sharp while you pinch, scroll, and mark them up. Ink, highlights, and shapes live in a sidecar next to the PDF so the original file is never rewritten unless you export.

Two apps share one engine:

| App | Target | Who it is for |
| --- | --- | --- |
| **PagerMac** | macOS 14+ | Mouse, trackpad, and a Preview-like window |
| **PagerPad** | iPadOS 17+ | Fingers to scroll, Apple Pencil to draw |

---

## What you can do

**Read.** Continuous vertical pages, pinch zoom, fit-width, outline, page thumbnails, and in-document links. Search jumps through hits without blocking the UI.

**Select.** Cursor / Select on Mac drags out a text selection immediately. On iPad, Cursor long-presses to select; Markup tools apply a highlight, underline, or strike as soon as you tap a word or drag across a line.

**Markup.** Highlight, underline, and strike-out use the same color palette on both platforms. The live preview is the markup itself, not a blue selection.

**Draw.** Pressure-sensitive pen, translucent marker, and an eraser that cuts ink along the stroke — a fast swipe does not skip gaps between touch events. Partially erased strokes keep square ends instead of growing pointed tips.

**Insert.** Rectangles, ovals, lines, and free-text boxes. Text is edited in place; empty boxes do not linger in undo history.

**Keep your notes.** Annotations are stored beside the PDF as `Document.pdf.notes`, with a copy in Application Support if the folder is read-only. Export produces a flattened PDF with everything burned in.

**Undo.** History records only the annotations an edit touched, so undo cost follows the change, not the size of the file.

---

## Architecture

PagerPDF is a small C++ core, a shared Objective-C++ canvas, and thin AppKit / UIKit hosts.

```
┌─────────────────────────────────────────────────────────────┐
│  PagerMac (AppKit)              PagerPad (UIKit)            │
│  PagerWindowController          ViewerViewController        │
│  PagerCanvasView                PadCanvasView               │
│  PagerDocument                  PadDocument                 │
└──────────────────────────┬──────────────────────────────────┘
                           │  PagerCanvasHost / SessionProvider
                           ▼
              ┌────────────────────────────┐
              │   PagerCanvasController    │
              │   tiles · chrome · gestures│
              └────────────┬───────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
   DocumentSession    Viewport         OverlayRenderer
   NoteDocument       TileCache        AnnotationRasterizer
   Ink / Geometry     PDFKitPageSource NoteArchive
```

**DocumentSession** is the live document: current tool and styles, text selection, search hits, the in-progress pen stroke, and a shape draft. It talks to **NoteDocument** for the annotation list and undo stack.

**Viewport** owns page layout and a worker pool that rasters PDF tiles. Layout is always in PDF points (scale 1). Pinch zoom is the scroll view’s magnification, so the canvas size does not jump when you zoom.

**PagerCanvasController** is the shared canvas. It places page and annotation `CALayer`s, runs every annotation gesture, and asks the host only for things that are truly platform-specific (the text editor, pan suspension, opening a link). Mac and iPad canvas views are hosts, not second copies of the interaction model.

**PDFKitPageSource** wraps PDFKit. Rasterization and flattened export use private `PDFDocument` instances so a slow page never blocks selection or search. Annotations that already exist in the PDF are imported for reference and left to PDFKit’s appearance streams — they are not painted again.

---

## How a page is drawn

Nothing is a document-sized bitmap.

1. Each PDF tile is a `CALayer` whose `contents` is a pre-rendered `CGImage`.
2. Committed notes are rasterized on a **separate thread** (`AnnotationRasterizer`) into transparent tiles, so scrolling never waits on ink and an edit never waits on a slow PDF page.
3. A low-resolution **base band** sits under the sharp tiles, so a fast scroll or pinch-out never flashes empty paper.
4. Live ink, a shape you are still dragging, and a note that just committed are drawn into a screen-sized overlay until their tiles arrive.
5. Selection, search hits, and resize handles are `CAShapeLayer`s.

Tiles are keyed by page, scale band (hundredths of zoom), column, and row. The cache is an LRU bounded by decoded bytes. During a live pinch only the cheap base rasters are requested; the current band refines when the gesture settles.

The desk behind the pages is a single gray (`pager::kCanvasGray`). Every surface that can show through uses that color so a zoom never looks like a flash.

---

## Tools

| Tool | What it does |
| --- | --- |
| Select / Cursor | Pan, follow links, select notes. On Mac, a drag on empty page selects text. |
| Text Selection | Explicit text-select tool (iPad read set; Mac toolbar). |
| Highlight / Underline / Strike | Drag or tap text; the mark is applied on lift, in the style color. |
| Pen | Pressure, tilt, and speed → a stable ballpoint ribbon. |
| Marker | Wide translucent stroke, no pressure. |
| Eraser | Sweeps a capsule between samples and splits ink on segments, not just at recorded points. |
| Rectangle / Oval / Line | Click-drag shapes. |
| Text Box | Tap to place, type in place. |

On a physical iPad, fingers pan and markup; Pencil is required for pen, marker, eraser, and insert tools. The simulator lets a finger stand in for the Pencil.

Color and size chips are defined once in `ToolPalette` so the iPad dock and the Mac markup bar offer the same choices.

---

## Notes on disk

Saves are a property list of annotations (kind, page, color, quads, ink samples, …). Geometry is stored as number arrays so values round-trip at full double precision. Older string-formatted archives still load.

Write path:

1. Debounced encode off the main thread.
2. Atomic write to `YourFile.pdf.notes` next to the PDF.
3. The same payload under `~/Library/Application Support/PagerPDF/Notes/<sha256>.plist`.

Load prefers whichever copy is newer, so a failed sidecar write (file provider, read-only folder) does not drop work. The PDF itself is left alone until **Export as Annotated PDF**.

---

## Project layout

```
Core/
  Include/          Public C++ headers (session, geometry, ink, viewport, …)
  Session/          DocumentSession, ToolPalette
  Annotations/      NoteDocument, hit testing, ink erase
  Geometry/         Page frames, zoom math
  Ink/              Stroke builder and ribbon triangulation
  Render/           Viewport workers and tile cache
  Bridge/           Canvas controller, PDFKit, overlay, archive (ObjC++)
Platform/
  Mac/              PagerMac — window, toolbar, sidebar, NSDocument
  Pad/              PagerPad — glass chrome, dock, UIDocument
Tests/
  PagerCoreTests.mm Geometry, tiles, ink, archive, canvas
gen_project.py      Regenerates PagerPDF.xcodeproj
```

Shared code is C++20. Platform and bridge files are Objective-C++. The Xcode project is generated; after adding a source file, run `python3 gen_project.py`.

---

## Build

Open `PagerPDF.xcodeproj` and pick a scheme:

| Scheme | Result |
| --- | --- |
| **PagerMac** | `PagerMac.app` |
| **PagerPad** | `PagerPad.app` (iPad device or simulator) |
| **PagerCoreTests** | Hosted in PagerMac; exercises core, archive, and the Mac canvas |

From the command line:

```bash
xcodebuild -scheme PagerMac -configuration Debug build
xcodebuild -scheme PagerPad -destination 'platform=iOS Simulator,name=iPad Pro 13-inch' build
xcodebuild -scheme PagerCoreTests test
```

Deployment targets are **macOS 14** and **iPadOS 17**. The apps link PDFKit, Core Text, and QuartzCore.

---

## Design notes

- **Layout stays in PDF points.** Zoom is a view transform. Tiles rendered at an old scale still sit on the same page frames, so they can remain visible as a pinch interpolates.
- **Main thread does not rasterize.** PDF workers and the annotation worker publish `CGImage`s; the canvas only attaches them to layers.
- **Gestures are document-space.** Hosts convert pointer events once. The controller does not know about `NSEvent` or `UITouch`.
- **Imported PDF annotations are not redrawn.** Re-stroking someone else’s appearance stream is how notes drift. Export is the one path that burns PagerPDF notes into page content.
