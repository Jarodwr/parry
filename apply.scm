;; apply.scm — the only module that touches the editor: building a Ctx for the
;; focused buffer, reading/setting the selection, applying Edits.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require (prefix-in hx. "helix/static.scm"))
(require "text.scm")
(require "dialect.scm")
(require "tree.scm")
(require "ops.scm")

(provide focused-doc-id
         current-ctx
         primary-span
         select-span!
         select-node!
         node-under-selection
         apply-edit!
         enter-insert-at!
         reveal-cursor!)

(define (focused-doc-id)
  (editor->doc-id (editor-focus)))

;;@doc
;; A Ctx for the focused buffer, or #f when it has no dialect or no tree.
(define (current-ctx)
  (let* ([doc-id (focused-doc-id)]
         [d (dialect-for-doc doc-id)])
    (and d
         (let* ([rope (editor->text doc-id)]
                [root (dialect-root d doc-id rope)])
           (and root (Ctx d rope root))))))

;;@doc
;; The primary selection as (from . to) CHAR offsets.
(define (primary-span)
  (let ([r (hx.selection->primary-range (hx.current-selection-object))])
    (cons (hx.range->from r) (hx.range->to r))))

(define (select-span! from to)
  (hx.set-current-selection-object! (hx.range->selection (hx.range from to))))

(define (select-node! ctx node)
  (when node
    (select-span! (node-start ctx node) (node-end ctx node))))

;;@doc
;; The node the primary selection is on, or #f. Whitespace at the selection's
;; edges is ignored (e.g. after `v` + `w` in Select mode), unless the
;; selection is nothing but whitespace.
(define (node-under-selection ctx)
  (let* ([span (primary-span)]
         [trimmed (trim-range (Ctx-rope ctx) (car span) (cdr span))]
         [span (if (< (car trimmed) (cdr trimmed)) trimmed span)])
    (current-node ctx (car span) (cdr span))))

;; `replace-selection-with` skips empty ranges, so a pure insertion is done by
;; replacing a neighbouring character with itself plus the new text.
(define (replace-chars! from to text)
  (let* ([rope (editor->text (focused-doc-id))]
         [len (text-len rope)])
    (cond
      [(< from to)
       (select-span! from to)
       (hx.replace-selection-with text)]
      [(< from len)
       (select-span! from (+ from 1))
       (hx.replace-selection-with (string-append text (string (char-at rope from))))]
      [(> from 0)
       (select-span! (- from 1) from)
       (hx.replace-selection-with (string-append (string (char-at rope (- from 1))) text))]
      [else
       (select-span! 0 0)
       (hx.insert_string text)])))

;;@doc
;; Apply `edit` and select the node at its tracked range. With `commit?`, the
;; change becomes its own undo step (Parry consumes the key, so Helix's editor
;; view never commits it for us).
(define (apply-edit! edit #:commit? (commit? #t))
  (replace-chars! (Edit-start edit) (Edit-end edit) (Edit-text edit))
  (let ([ctx (current-ctx)])
    (if ctx
        (let ([node (node-at-range ctx (Edit-track-start edit) (Edit-track-end edit))])
          (if node
              (select-node! ctx node)
              (select-span! (Edit-track-start edit) (Edit-track-start edit))))
        (select-span! (Edit-track-start edit) (Edit-track-start edit))))
  (when commit?
    (hx.commit_undo_checkpoint)))

;;@doc
;; Put the cursor at CHAR offset `at` and switch to Insert mode there.
(define (enter-insert-at! at)
  (select-span! at at)
  (hx.insert_mode))

;;@doc
;; Recentre the view if the cursor ended up off screen. Helix normally does
;; this after each key, but not for keys a component consumes.
(define (reveal-cursor!)
  (let ([c (current-cursor)])
    (unless (and c (car c))
      (hx.align_view_center))))
