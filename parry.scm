;; parry.scm — Parry: structural editing for Lisp dialects in Helix.
;;
;; `:parry-enter` pushes an invisible component on top of the editor. While
;; Helix is in Normal mode in a buffer with a Parry dialect, that component
;; takes every key: Parry's own keys run structural commands, a few keys pass
;; straight through to Helix, and everything else does nothing. In Insert or
;; Select mode, and in any other buffer, every event goes to Helix untouched,
;; so `i` … `Esc` and `v` … `Esc` land back in Parry. `Esc` in Parry leaves it.
;;
;; The selection is Parry's only state: each command starts from the node the
;; primary selection is on and ends by selecting the node it moved to or made.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/components.scm")
(require "helix/configuration.scm")
(require "helix/treesitter.scm")
(require (prefix-in hx. "helix/static.scm"))
(require-builtin helix/core/keymaps as helix.keymaps.)
(require "text.scm")
(require "dialect.scm")
(require "tree.scm")
(require "ops.scm")
(require "apply.scm")
(require "dialects/fennel.scm")
(require "test.scm")

(provide parry-enter
         parry-exit
         parry-self-test
         parry-active?
         define-parry-dialect
         set-parry-pass-through!
         set-parry-sibling-style!
         ;; commands, also usable as typed commands / in other keymaps
         parry-prev
         parry-next
         parry-first-child
         parry-last-child
         parry-parent
         parry-insert-before
         parry-insert-after
         parry-change
         parry-new-comment
         parry-slurp-forward
         parry-slurp-backward
         parry-barf-forward
         parry-barf-backward
         parry-raise
         parry-wrap
         parry-splice
         parry-delete
         parry-toggle-layout
         parry-swap-next
         parry-swap-prev
         parry-undo
         parry-redo)

;;;; State ------------------------------------------------------------------

(define *active* #f)
;; the user's cursor shape for Normal mode, restored on exit / outside Parry
(define *saved-cursor* "block")
;; whether the hidden-cursor shape is currently applied
(define *cursor-hidden* #f)
;; first keys that go straight to Helix
(define *pass-through* '(":" "space" "v"))
;; keys of an in-progress pass-through sequence, or #f
(define *pt-seq* #f)
;; every proper prefix of a Helix Normal-mode key sequence, joined by " "
(define *prefixes* (hash))
;; CHAR offset where the current Insert session started, and the buffer length
;; at that moment (to measure what was typed); #f outside Parry inserts
(define *insert-start* #f)
(define *insert-len* 0)

(define (parry-active?)
  *active*)

;;@doc
;; Set the first keys that go straight to Helix while Parry is active.
;; Default: '(":" "space" "v").
(define (set-parry-pass-through! keys)
  (set! *pass-through* keys))

;;;; Command plumbing -------------------------------------------------------

;; Run `f` with the focused buffer's Ctx and current node, if any.
(define (with-node f)
  (let ([ctx (current-ctx)])
    (when ctx
      (let ([node (node-under-selection ctx)])
        (when node
          (f ctx node))))))

(define (move! target)
  (with-node (lambda (ctx node)
               (let ([dest (target ctx node)])
                 (if dest
                     (select-node! ctx dest)
                     (select-node! ctx node))))))

(define (edit! op)
  (with-node (lambda (ctx node)
               (let ([edit (op ctx node)])
                 (if edit
                     (apply-edit! edit)
                     (select-node! ctx node))))))

;; Insert the scaffold from (cons Edit insert-at) and start Insert mode in it.
;; The scaffold isn't committed on its own: it joins the Insert session's
;; undo step.
(define (insert-with! placement)
  (let ([edit (car placement)]
        [at (cdr placement)])
    (apply-edit! edit #:commit? #f)
    (set! *insert-start* at)
    (set! *insert-len* (text-len (editor->text (focused-doc-id))))
    (enter-insert-at! at)))

;;;; Commands ---------------------------------------------------------------

;;@doc
;; Select the previous sibling.
(define (parry-prev)
  (move! (lambda (ctx n) (prev-sibling n))))

;;@doc
;; Select the next sibling.
(define (parry-next)
  (move! (lambda (ctx n) (next-sibling n))))

;;@doc
;; Select the first child.
(define (parry-first-child)
  (move! first-child))

;;@doc
;; Select the last child.
(define (parry-last-child)
  (move! last-child))

;;@doc
;; Select the enclosing form.
(define (parry-parent)
  (move! parent-form))

;;@doc
;; Insert before the current node.
(define (parry-insert-before)
  (with-node (lambda (ctx node) (insert-with! (adjacent-insert ctx node 'before)))))

;;@doc
;; Insert after the current node.
(define (parry-insert-after)
  (with-node (lambda (ctx node) (insert-with! (adjacent-insert ctx node 'after)))))

;;@doc
;; Replace the current atom: delete it and start Insert mode in its place.
(define (parry-change)
  (with-node (lambda (ctx node)
               (unless (container? ctx node)
                 (select-node! ctx node)
                 (set! *insert-start* (node-start ctx node))
                 (set! *insert-len*
                       (- (text-len (Ctx-rope ctx)) (- (node-end ctx node) (node-start ctx node))))
                 (hx.change_selection)))))

(define (new-form! pair direction)
  (let ([ctx (current-ctx)])
    (when ctx
      (insert-with!
       (new-form-insert ctx (node-under-selection ctx) direction pair (car (primary-span)))))))

;;@doc
;; New comment line above the current node.
(define (parry-new-comment)
  (let ([ctx (current-ctx)])
    (when ctx
      (insert-with! (comment-insert ctx (node-under-selection ctx) (car (primary-span)))))))

;;@doc
;; Grow the enclosing form over the next sibling.
(define (parry-slurp-forward)
  (edit! slurp-forward))

;;@doc
;; Grow the enclosing form over the previous sibling.
(define (parry-slurp-backward)
  (edit! slurp-backward))

;;@doc
;; Push the enclosing form's last element out after it.
(define (parry-barf-forward)
  (edit! barf-forward))

;;@doc
;; Push the enclosing form's first element out before it.
(define (parry-barf-backward)
  (edit! barf-backward))

;;@doc
;; Replace the parent form with the current node.
(define (parry-raise)
  (edit! raise))

;;@doc
;; Wrap the current node in brackets.
(define (parry-wrap)
  (edit! wrap))

;;@doc
;; Remove the enclosing form's brackets.
(define (parry-splice)
  (edit! splice))

;;@doc
;; Delete the current node.
(define (parry-delete)
  (edit! delete-node))

;;@doc
;; Swap the current node with its next sibling.
(define (parry-swap-next)
  (edit! (lambda (ctx node) (swap ctx node 'next))))

;;@doc
;; Swap the current node with its previous sibling.
(define (parry-swap-prev)
  (edit! (lambda (ctx node) (swap ctx node 'prev))))

;;@doc
;; Toggle the following siblings between one line and one per line.
(define (parry-toggle-layout)
  (edit! toggle-layout))

(define (resnap!)
  (let ([ctx (current-ctx)])
    (when ctx
      (select-node! ctx (node-under-selection ctx)))))

;;@doc
;; Undo, then select the node there.
(define (parry-undo)
  (hx.undo)
  (resnap!))

;;@doc
;; Redo, then select the node there.
(define (parry-redo)
  (hx.redo)
  (resnap!))

;;;; Keys -------------------------------------------------------------------

(define (base-bindings)
  (hash "h"
        parry-prev
        "l"
        parry-next
        "j"
        parry-first-child
        "J"
        parry-last-child
        "k"
        parry-parent
        "i"
        parry-insert-before
        "a"
        parry-insert-after
        "c"
        parry-change
        ";"
        parry-new-comment
        "s"
        parry-slurp-forward
        "S"
        parry-slurp-backward
        "b"
        parry-barf-forward
        "B"
        parry-barf-backward
        "r"
        parry-raise
        "w"
        parry-wrap
        "W"
        parry-splice
        "d"
        parry-delete
        "m"
        parry-toggle-layout
        "A-l"
        parry-swap-next
        "A-h"
        parry-swap-prev
        "u"
        parry-undo
        "U"
        parry-redo))

;; Bindings for the focused buffer: the base table plus, for each of its
;; dialect's bracket pairs, open = new form before, close = new form after.
(define (bindings-for d)
  (let loop ([pairs (Dialect-brackets d)] [table (base-bindings)])
    (if (null? pairs)
        table
        (let ([pair (car pairs)])
          (loop (cdr pairs)
                (hash-insert (hash-insert table (car pair) (lambda () (new-form! pair 'before)))
                             (cadr pair)
                             (lambda () (new-form! pair 'after))))))))

(define (char->key-name c)
  (cond
    [(equal? c #\space) "space"]
    [(equal? c #\-) "minus"]
    [(equal? c #\<) "lt"]
    [(equal? c #\>) "gt"]
    [else (string c)]))

(define (modifier? mods bit)
  (not (= 0 (bitwise-and mods bit))))

;; A key event as Helix writes key names ("x", "C-x", "space", "esc", ...).
(define (event->key-name event)
  (let* ([mods (or (key-event-modifier event) 0)]
         [prefix (string-append (if (modifier? mods key-modifier-alt) "A-" "")
                                (if (modifier? mods key-modifier-ctrl) "C-" ""))]
         [c (key-event-char event)])
    (string-append prefix
                   (cond
                     [c (char->key-name c)]
                     [(key-event-escape? event) "esc"]
                     [(key-event-enter? event) "ret"]
                     [(key-event-backspace? event) "backspace"]
                     [(key-event-tab? event) "tab"]
                     [(key-event-delete? event) "del"]
                     [(key-event-left? event) "left"]
                     [(key-event-right? event) "right"]
                     [(key-event-up? event) "up"]
                     [(key-event-down? event) "down"]
                     [else "?"]))))

;; Record every proper prefix of Helix's current Normal-mode key sequences, so
;; a passed-through `space` keeps passing keys until the sequence completes.
(define (compute-prefixes!)
  (set! *prefixes*
        (with-handler
         (lambda (_) (hash))
         (let loop ([paths (helix.keymaps.flatten-keymap (get-keybindings) "normal")] [acc (hash)])
           (if (null? paths)
               acc
               (let* ([keys (reverse (cdr (reverse (car paths))))] ; drop the command name
                      [acc (let inner ([i 1] [acc acc])
                             (if (>= i (length keys))
                                 acc
                                 (inner (+ i 1) (hash-insert acc (join (take keys i) " ") #t))))])
                 (loop (cdr paths) acc)))))))

(define (prefix? keys)
  (hash-contains? *prefixes* (join keys " ")))

;;;; Display ----------------------------------------------------------------

(define (set-cursor-hidden! hidden?)
  (unless (equal? hidden? *cursor-hidden*)
    (set! *cursor-hidden* hidden?)
    (set-option! "cursor-shape.normal" (if hidden? "hidden" *saved-cursor*))))

(define parry-label-style (style-with-bold (style-fg (style) Color/Magenta)))

(define *status-pushed* #f)

(define (push-status!)
  (unless *status-pushed*
    (set! *status-pushed* #t)
    (push-status-element! 'left
                          ;; called per view with (view-id focused?), despite the
                          ;; upstream doc saying DocumentId
                          (status-element (lambda (view-id focused?)
                                            (if (and *active*
                                                     focused?
                                                     (dialect-for-doc (editor->doc-id view-id)))
                                                (list (span " PARRY " parry-label-style))
                                                '()))))))

;;;; Component --------------------------------------------------------------

(define (in-parry-buffer?)
  (and (dialect-for-doc (focused-doc-id)) #t))

(define (handle-key event)
  (let ([key (event->key-name event)])
    (cond
      [*pt-seq*
       (let ([seq (append *pt-seq* (list key))])
         (set! *pt-seq* (if (and (not (equal? key "esc")) (prefix? seq)) seq #f)))
       event-result/ignore]
      [(member key *pass-through*)
       (set! *pt-seq* (if (prefix? (list key)) (list key) #f))
       event-result/ignore]
      [(equal? key "esc")
       (deactivate!)
       event-result/close]
      [else
       (let* ([d (dialect-for-doc (focused-doc-id))]
              [command (hash-try-get (bindings-for d) key)])
         (when command
           (command)
           (reveal-cursor!))
         event-result/consume)])))

(define (parry-handle-event state event)
  (let ([here? (in-parry-buffer?)])
    ;; the option only shapes the Normal-mode cursor, so Insert/Select are
    ;; unaffected; it's restored while focus is in a non-Parry buffer
    (set-cursor-hidden! here?)
    (cond
      [(not here?) event-result/ignore]
      [(not (equal? (editor-mode) 'normal)) event-result/ignore]
      [(not (key-event? event)) event-result/ignore]
      [else (handle-key event)])))

;;;; Sibling marks ---------------------------------------------------------
;; The first character of every other node at the current node's level is
;; painted over the editor, so you can see where `h`/`l` lead.
;;
;; Steel exposes no buffer-position → screen-position mapping, only the
;; primary cursor's screen position. Every other position is derived from it
;; by line and column offset, which holds as long as the lines involved have
;; no soft wraps, tabs or double-width characters.

;; #f = the theme's `ui.cursor.match`; otherwise a Style
(define *sibling-style* #f)

;;@doc
;; Set the style for sibling marks (a Style, see helix/components.scm), or #f
;; for the theme's `ui.cursor.match`.
(define (set-parry-sibling-style! style)
  (set! *sibling-style* style))

;; Start offsets of the current node's siblings (excluding itself).
(define (sibling-starts ctx node)
  (let ([p (tsnode-parent node)])
    (if p
        (map (lambda (k) (node-start ctx k))
             (filter (lambda (k) (not (node=? k node))) (named-kids p)))
        '())))

(define (draw-sibling-marks! buffer)
  (let* ([ctx (current-ctx)]
         [node (and ctx (node-under-selection ctx))]
         [cursor (current-cursor)]
         [screen (and cursor (car cursor))]
         [area (editor-focused-buffer-area)])
    (when (and node screen area)
      (let* ([rope (Ctx-rope ctx)]
             [span (primary-span)]
             ;; the char Helix draws the cursor on: the head, minus one for a
             ;; forward selection
             [head (if (> (cdr span) (car span)) (- (cdr span) 1) (car span))]
             [head-line (line-of rope head)]
             [head-col (- head (line-start rope head-line))]
             [row0 (- (position-row screen) head-line)]
             [col0 (- (position-col screen) head-col)]
             [style (or *sibling-style* (theme-scope-ref "ui.cursor.match"))])
        (for-each (lambda (start)
                    (let* ([line (line-of rope start)]
                           [y (+ row0 line)]
                           [x (+ col0 (- start (line-start rope line)))])
                      (when (and (>= y (area-y area))
                                 (< y (+ (area-y area) (area-height area)))
                                 (>= x (area-x area))
                                 (< x (+ (area-x area) (area-width area))))
                        (frame-set-string! buffer x y (string (char-at rope start)) style))))
                  (sibling-starts ctx node))))))

(define (parry-render state rect buffer)
  (when (and *active* (equal? (editor-mode) 'normal) (in-parry-buffer?))
    ;; a drawing failure must never take the editor down with it
    (with-handler (lambda (_) #f) (draw-sibling-marks! buffer)))
  #t)

(define (parry-cursor state rect)
  #f)

(define (deactivate!)
  (set! *active* #f)
  (set! *pt-seq* #f)
  (set! *insert-start* #f)
  (set-cursor-hidden! #f))

;;@doc
;; Enter Parry in the focused buffer.
(define (parry-enter)
  (cond
    [*active* (set-status! "Parry is already active")]
    [(not (current-ctx))
     (let* ([path (editor-document->path (focused-doc-id))]
            [ext (and path (path-extension path))])
       (set-error! (string-append "Parry: no dialect for "
                                  (if ext (string-append "." ext) "this buffer"))))]
    [else
     (set! *active* #t)
     (set! *saved-cursor*
           (with-handler (lambda (_) "block") (get-config-option-value "cursor-shape.normal")))
     (set! *cursor-hidden* #f)
     (compute-prefixes!)
     (push-status!)
     (hx.keep_primary_selection)
     (resnap!)
     (set-cursor-hidden! #t)
     (push-component! (new-component! "parry"
                                      (hash)
                                      parry-render
                                      (hash "handle_event" parry-handle-event "cursor" parry-cursor)))]))

;;@doc
;; Leave Parry.
(define (parry-exit)
  (when *active*
    (deactivate!)
    (pop-last-component-by-name! "parry")))

;;;; Returning from Insert / Select -----------------------------------------

;; Re-select a node after Insert mode: the node covering what was typed (the
;; buffer grew by that much from where Insert started), or the node at the
;; cursor when nothing was added.
(define (resync-after-insert!)
  (let ([ctx (current-ctx)]
        [start *insert-start*])
    (set! *insert-start* #f)
    (when ctx
      (let* ([rope (Ctx-rope ctx)]
             [typed (- (text-len rope) *insert-len*)]
             [span (if (> typed 0) (trim-range rope start (+ start typed)) (cons start start))]
             [node (node-at-range ctx (car span) (cdr span))])
        (if node
            (select-node! ctx node)
            (resnap!))))))

(register-hook 'on-mode-switch
               (lambda (event)
                 (when (and *active* (equal? (mode-switch-new event) 'normal) (in-parry-buffer?))
                   (if *insert-start*
                       (resync-after-insert!)
                       (resnap!)))))
