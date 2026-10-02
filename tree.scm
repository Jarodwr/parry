;; tree.scm — reading the syntax tree: node geometry, navigation, and finding
;; the "current" node for a selection. Ported from fennel-editor's
;; src/paredit/commands.ts. Everything here is pure: it reads a Ctx and
;; returns nodes or offsets, never touching the editor.

(require "helix/treesitter.scm")
(require "text.scm")
(require "dialect.scm")

(provide Ctx
         Ctx?
         Ctx-dialect
         Ctx-rope
         Ctx-root
         node-start
         node-end
         node-text
         node=?
         root?
         named-kids
         index-of
         find-first
         container?
         comment?
         string-node?
         open-delim
         close-delim
         delim-prefix-end
         prev-sibling
         next-sibling
         first-child
         last-child
         parent-form
         form-of
         inner
         enclosing-container
         element-and-outer-container
         current-node
         node-at-range)

;; dialect : Dialect, rope : Rope, root : TSNode
(struct Ctx (dialect rope root) #:transparent)

;;;; Geometry (CHAR offsets) -------------------------------------------------

(define (node-start ctx n)
  (byte->char (Ctx-rope ctx) (tsnode-start-byte n)))

(define (node-end ctx n)
  (byte->char (Ctx-rope ctx) (tsnode-end-byte n)))

(define (node-text ctx n)
  (slice-text (Ctx-rope ctx) (node-start ctx n) (node-end ctx n)))

;; Steel node values have no stable identity; compare by span and kind.
(define (node=? a b)
  (and a
       b
       (= (tsnode-start-byte a) (tsnode-start-byte b))
       (= (tsnode-end-byte a) (tsnode-end-byte b))
       (equal? (tsnode-kind a) (tsnode-kind b))))

(define (root? n)
  (not (tsnode-parent n)))

(define (named-kids n)
  (tsnode-named-children n))

(define (find-first pred lst)
  (cond
    [(null? lst) #f]
    [(pred (car lst)) (car lst)]
    [else (find-first pred (cdr lst))]))

(define (index-of n lst)
  (let loop ([lst lst] [i 0])
    (cond
      [(null? lst) #f]
      [(node=? n (car lst)) i]
      [else (loop (cdr lst) (+ i 1))])))

;;;; Roles (asked of the dialect) -------------------------------------------

(define (container? ctx n)
  (and (member (tsnode-kind n) (Dialect-containers (Ctx-dialect ctx))) #t))

(define (comment? ctx n)
  (or (and (member (tsnode-kind n) (Dialect-comment-kinds (Ctx-dialect ctx))) #t)
      (and (tsnode-extra? n) (tsnode-named? n))))

(define (string-node? ctx n)
  (and (member (tsnode-kind n) (Dialect-string-kinds (Ctx-dialect ctx))) #t))

(define (opens ctx)
  (map car (Dialect-brackets (Ctx-dialect ctx))))

(define (closes ctx)
  (map cadr (Dialect-brackets (Ctx-dialect ctx))))

;;@doc
;; The anonymous child of container `n` holding its opening bracket, or #f.
;; (The Steel node API has no field access, so this matches bracket text
;; instead of commands.ts's childForFieldName("open").)
(define (open-delim ctx n)
  (find-first (lambda (c) (and (not (tsnode-named? c)) (member (node-text ctx c) (opens ctx))))
              (tsnode-children n)))

;;@doc
;; The anonymous child of container `n` holding its closing bracket, or #f.
(define (close-delim ctx n)
  (find-first (lambda (c) (and (not (tsnode-named? c)) (member (node-text ctx c) (closes ctx))))
              (reverse (tsnode-children n))))

;;@doc
;; End of `n`'s opening delimiter, including any reader prefix before it
;; (e.g. `#(` in Fennel's hashfn).
(define (delim-prefix-end ctx n)
  (let ([open (open-delim ctx n)])
    (if open (node-end ctx open) (node-start ctx n))))

;;;; Navigation -------------------------------------------------------------

(define (siblings n)
  (let ([p (tsnode-parent n)])
    (if p (named-kids p) '())))

;;@doc
;; `h`: the previous named sibling, or #f.
(define (prev-sibling n)
  (let loop ([kids (siblings n)] [prev #f])
    (cond
      [(null? kids) #f]
      [(node=? n (car kids)) prev]
      [else (loop (cdr kids) (car kids))])))

;;@doc
;; `l`: the next named sibling, or #f.
(define (next-sibling n)
  (let loop ([kids (siblings n)])
    (cond
      [(or (null? kids) (null? (cdr kids))) #f]
      [(node=? n (car kids)) (cadr kids)]
      [else (loop (cdr kids))])))

;; Strings and comments have named inner nodes (string_content, comment_body)
;; but are edited as single atoms: never descended into, and a selection
;; inside one resolves to the whole literal.
(define (atomic? ctx n)
  (or (string-node? ctx n) (comment? ctx n)))

;; A node that only adds a prefix to one form, ending where it ends: a reader
;; macro such as Fennel's `#(...)`, `'x`, `` `x ``, `,x` — or a wrapper with
;; the exact same span. Its single named child is the form it wraps.
(define (wraps? ctx p n)
  (and p
       (not (root? p))
       (not (container? ctx p))
       (= (tsnode-end-byte p) (tsnode-end-byte n))
       (let ([kids (named-kids p)])
         (and (= (length kids) 1) (node=? (car kids) n)))))

;;@doc
;; The outermost wrapper around `n` (see `wraps?`), or `n` itself. Bracket
;; ops measure a form from here so its prefix travels with it.
(define (form-of ctx n)
  (let ([p (tsnode-parent n)])
    (if (wraps? ctx p n) (form-of ctx p) n)))

;; The form inside any wrappers, for descending into its children.
(define (inner ctx n)
  (let ([kids (named-kids n)])
    (if (and (= (length kids) 1) (wraps? ctx n (car kids))) (inner ctx (car kids)) n)))

;;@doc
;; `j`: the first named child, or #f.
(define (first-child ctx n)
  (let ([kids (if (atomic? ctx n) '() (named-kids (inner ctx n)))])
    (if (null? kids) #f (outermost ctx (car kids)))))

;;@doc
;; `J`: the last named child, or #f.
(define (last-child ctx n)
  (let ([kids (if (atomic? ctx n) '() (named-kids (inner ctx n)))])
    (if (null? kids) #f (outermost ctx (last kids)))))

;; "The" node for `n`: lifted out of any enclosing string or comment, and out
;; to its outermost wrapper, so `k` never appears to do nothing and a reader
;; macro moves with its form.
(define (outermost ctx n)
  (let ([lit (let loop ([p (tsnode-parent n)])
               (cond
                 [(or (not p) (root? p)) #f]
                 [(atomic? ctx p) p]
                 [else (loop (tsnode-parent p))]))])
    (if lit (outermost ctx lit) (form-of ctx n))))

;;@doc
;; `k`: the enclosing form, or #f for a top-level form.
(define (parent-form ctx n)
  (let ([p (tsnode-parent (form-of ctx n))])
    (if (or (not p) (root? p)) #f (outermost ctx p))))

;;@doc
;; The nearest container at or above `n`, or #f (port of enclosingContainer).
(define (enclosing-container ctx n)
  (let loop ([c (let ([n (inner ctx n)]) (if (container? ctx n) n (tsnode-parent n)))])
    (cond
      [(not c) #f]
      [(container? ctx c) c]
      [else (loop (tsnode-parent c))])))

;;@doc
;; `n` as an element of the bracketed form containing it: (element . container),
;; walking through non-bracketed wrappers. #f for a top-level form.
(define (element-and-outer-container ctx n)
  (let loop ([element n])
    (let ([p (tsnode-parent element)])
      (cond
        [(not p) #f]
        [(container? ctx p) (cons element p)]
        [else (loop p)]))))

;;;; Current node -----------------------------------------------------------

(define (descendant ctx from to)
  (let ([rope (Ctx-rope ctx)])
    (tsnode-descendant-byte-range (Ctx-root ctx) (char->byte rope from) (char->byte rope to))))

;;@doc
;; The node a selection [from, to) is "on" (port of currentSexpNode, adapted to
;; Helix's always-at-least-one-char selections):
;; * on a bracket character → the form it delimits
;; * exactly covering a node, or inside an atom → that node
;; * in the gap between children → the child just before the gap, else the
;;   one just after; at top level, the nearest preceding form
;; * spanning several children → their smallest common ancestor
(define (current-node ctx from to)
  (let ([n (descendant ctx from to)])
    (cond
      [(not n) #f]
      [(not (tsnode-named? n))
       (let ([p (tsnode-parent n)])
         (and p (not (root? p)) (outermost ctx p)))]
      [else
       (let ([kids (named-kids n)])
         (cond
           [(and (not (root? n)) (or (null? kids) (and (= (node-start ctx n) from) (= (node-end ctx n) to))))
            (outermost ctx n)]
           [else
            (or (find-first (lambda (k) (= (node-end ctx k) from)) kids)
                (find-first (lambda (k) (= (node-start ctx k) to)) kids)
                (and (root? n)
                     (or (let loop ([kids kids] [best #f])
                           (cond
                             [(null? kids) best]
                             [(<= (node-end ctx (car kids)) from) (loop (cdr kids) (car kids))]
                             [else best]))
                         (and (not (null? kids)) (car kids))))
                (and (not (root? n)) (outermost ctx n)))]))])))

;;@doc
;; The node for a tracked post-edit range [start, end): a real span resolves
;; like a selection; an empty one like a cursor on the char at `start`.
(define (node-at-range ctx start end)
  (let ([len (text-len (Ctx-rope ctx))])
    (cond
      [(< start end) (current-node ctx start end)]
      [(< start len) (current-node ctx start (+ start 1))]
      [(> start 0) (current-node ctx (- start 1) start)]
      [else #f])))
