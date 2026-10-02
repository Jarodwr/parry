;; ops.scm — structural edits, ported from fennel-editor's commands.ts.
;;
;; Each op is pure: given a Ctx and the current node it returns an Edit (one
;; text replacement plus the post-edit range of the node to select afterwards)
;; or #f when it doesn't apply. apply.scm performs the edit. One Edit per op
;; keeps every op a single undo step.

(require "helix/treesitter.scm")
(require "text.scm")
(require "dialect.scm")
(require "tree.scm")

(provide Edit
         Edit?
         Edit-start
         Edit-end
         Edit-text
         Edit-track-start
         Edit-track-end
         slurp-forward
         slurp-backward
         barf-forward
         barf-backward
         raise
         wrap
         splice
         delete-node
         swap
         toggle-layout
         adjacent-insert
         new-form-insert
         comment-insert)

;; Replace CHAR range [start, end) with `text`; afterwards select the node at
;; post-edit range [track-start, track-end).
(struct Edit (start end text track-start track-end) #:transparent)

(define (len s)
  (string-length s))

;; A comment runs to the end of its line, so moving a bracket next to one (or
;; joining text onto its line) would comment the bracket out.
(define (comment-safe? ctx . nodes)
  (not (find-first (lambda (n) (and n (comment? ctx n))) nodes)))

;; Text of container `c` up to and including its open bracket (keeps reader
;; prefixes such as `#(`).
(define (open-text ctx c)
  (slice-text (Ctx-rope ctx) (form-start ctx c) (delim-prefix-end ctx c)))

;; Where container `c` starts once its reader-macro prefix is included.
(define (form-start ctx c)
  (node-start ctx (form-of ctx c)))

;;;; Slurp / barf -----------------------------------------------------------

;;@doc
;; `s`: grow the enclosing form to take in the sexp right after it.
(define (slurp-forward ctx node)
  (let* ([c (enclosing-container ctx node)]
         [close (and c (close-delim ctx c))]
         [target (and c (next-sibling (form-of ctx c)))])
    (and c
         close
         target
         (comment-safe? ctx target)
         (let* ([start (node-start ctx close)]
                [text (string-append " " (node-text ctx target) (node-text ctx close))])
           (Edit start (node-end ctx target) text (form-start ctx c) (+ start (len text)))))))

;;@doc
;; `S`: grow the enclosing form to take in the sexp right before it.
(define (slurp-backward ctx node)
  (let* ([c (enclosing-container ctx node)]
         [open (and c (open-delim ctx c))]
         [target (and c (prev-sibling (form-of ctx c)))])
    (and c
         open
         target
         (comment-safe? ctx target)
         (let* ([start (node-start ctx target)]
                [end (node-end ctx open)]
                [text (string-append (open-text ctx c) (node-text ctx target) " ")])
           (Edit start end text start (+ (node-end ctx c) (- (len text) (- end start))))))))

;;@doc
;; `b`: shrink the enclosing form by pushing its last element out after it.
(define (barf-forward ctx node)
  (let* ([c (enclosing-container ctx node)]
         [kids (if c (named-kids c) '())]
         [close (and c (close-delim ctx c))])
    (and c
         close
         (not (null? kids))
         (let* ([ejected (last kids)]
                [before (if (>= (length kids) 2) (list-ref kids (- (length kids) 2)) #f)]
                [start (if before (node-end ctx before) (delim-prefix-end ctx c))])
           (and (comment-safe? ctx before)
                (let ([close-text (node-text ctx close)])
                  (Edit start
                        (node-end ctx close)
                        (string-append close-text " " (node-text ctx ejected))
                        (form-start ctx c)
                        (+ start (len close-text)))))))))

;;@doc
;; `B`: shrink the enclosing form by pushing its first element out before it.
(define (barf-backward ctx node)
  (let* ([c (enclosing-container ctx node)]
         [kids (if c (named-kids c) '())]
         [close (and c (close-delim ctx c))])
    (and c
         close
         (open-delim ctx c)
         (not (null? kids))
         (comment-safe? ctx (car kids))
         (let* ([ejected-text (node-text ctx (car kids))]
                [start (form-start ctx c)]
                [end (if (>= (length kids) 2) (node-start ctx (cadr kids)) (node-start ctx close))]
                [text (string-append ejected-text " " (open-text ctx c))])
           (Edit start
                 end
                 text
                 (+ start (len ejected-text) 1)
                 (+ (node-end ctx c) (- (len text) (- end start))))))))

;;;; Raise / wrap / splice / delete ----------------------------------------

;;@doc
;; `r`: replace the parent form with the current node, dropping its siblings.
(define (raise ctx node)
  (let ([p (parent-form ctx node)])
    (and p
         (let ([start (node-start ctx p)]
               [text (node-text ctx node)])
           (Edit start (node-end ctx p) text start (+ start (len text)))))))

;;@doc
;; `w`: wrap the current node in the dialect's first bracket pair.
(define (wrap ctx node)
  (let* ([pair (car (Dialect-brackets (Ctx-dialect ctx)))]
         [start (node-start ctx node)]
         [text (string-append (car pair) (node-text ctx node) (cadr pair))])
    (Edit start (node-end ctx node) text start (+ start (len text)))))

;;@doc
;; `W`: remove the enclosing form's brackets, splicing its contents into its
;; parent. Keeps the current node selected if it survives, else the form's
;; first child, else the parent.
(define (splice ctx node)
  (let* ([c (enclosing-container ctx node)]
         [close (and c (close-delim ctx c))])
    (and c
         close
         (open-delim ctx c)
         (let* ([start (form-start ctx c)]
                [end (node-end ctx c)]
                [inner-start (delim-prefix-end ctx c)]
                [text (slice-text (Ctx-rope ctx) inner-start (node-start ctx close))]
                [kids (named-kids c)]
                [landmark (cond
                            [(not (node=? (form-of ctx node) (form-of ctx c))) node]
                            [(not (null? kids)) (car kids)]
                            [else (or (parent-form ctx c) c)])]
                [remap (lambda (o)
                         (cond
                           [(<= o start) o]
                           [(>= o end) (+ o (- (len text) (- end start)))]
                           [else (- o (- inner-start start))]))])
           (Edit start
                 end
                 text
                 (remap (node-start ctx landmark))
                 (remap (node-end ctx landmark)))))))

;;@doc
;; `d`: delete the current node plus one neighbouring gap; select the next
;; sibling, else the previous one, else the parent form.
(define (delete-node ctx node)
  (let* ([prev (prev-sibling node)]
         [next (next-sibling node)]
         [start (if prev (node-end ctx prev) (node-start ctx node))]
         [end (cond
                [prev (node-end ctx node)]
                [next (node-start ctx next)]
                [else (node-end ctx node)])]
         [removed (- end start)]
         [remap (lambda (o) (if (>= o end) (- o removed) o))]
         [target (or next prev (parent-form ctx node))])
    (if target
        (Edit start end "" (remap (node-start ctx target)) (remap (node-end ctx target)))
        (Edit start end "" start start))))

;;@doc
;; `A-l` / `A-h`: swap the current node with the next / previous sibling,
;; stepping over comments. Everything between the two (gaps, comments, line
;; breaks) stays where it is, so no code can end up after a comment on its
;; line. The node stays selected, so repeating the key carries it along.
;; Refuses when the current node is itself a comment.
(define (swap ctx node direction)
  (let ([other (let loop ([n (if (equal? direction 'next) (next-sibling node) (prev-sibling node))])
                 (cond
                   [(not n) #f]
                   [(comment? ctx n) (loop (if (equal? direction 'next) (next-sibling n) (prev-sibling n)))]
                   [else n]))])
    (and other
         (not (comment? ctx node))
         (let* ([first (if (equal? direction 'next) node other)]
                [second (if (equal? direction 'next) other node)]
                [start (node-start ctx first)]
                [gap (slice-text (Ctx-rope ctx) (node-end ctx first) (node-start ctx second))]
                [first-text (node-text ctx first)]
                [second-text (node-text ctx second)]
                [track (if (equal? direction 'next) (+ start (len second-text) (len gap)) start)])
           (Edit start
                 (node-end ctx second)
                 (string-append second-text gap first-text)
                 track
                 (+ track (len (node-text ctx node))))))))

;;;; Toggle layout ----------------------------------------------------------

(define (multi-line? ctx n)
  (let ([rope (Ctx-rope ctx)])
    (not (= (line-of rope (node-start ctx n)) (line-of rope (node-end ctx n))))))

;; A comment, or a multi-line string, anywhere inside `n`: collapsing either
;; onto one line would change meaning.
(define (uncollapsible? ctx n)
  (cond
    [(comment? ctx n) #t]
    [(string-node? ctx n) (multi-line? ctx n)]
    [else (and (find-first (lambda (k) (uncollapsible? ctx k)) (named-kids n)) #t)]))

;; `n`'s text with every internal line break flattened, re-hugging nested
;; brackets (port of collapsedText).
(define (collapsed-text ctx n)
  (let ([rope (Ctx-rope ctx)]
        [kids (named-kids n)])
    (cond
      [(and (container? ctx n) (open-delim ctx n) (close-delim ctx n))
       (string-append (open-text ctx n)
                      (join (map (lambda (k) (collapsed-text ctx k)) kids) " ")
                      (node-text ctx (close-delim ctx n)))]
      [(null? kids) (node-text ctx n)]
      [else
       (let loop ([kids kids] [cursor (node-start ctx n)] [acc ""])
         (if (null? kids)
             (let ([gap (slice-text rope cursor (node-end ctx n))])
               (string-append acc (if (has-newline? gap) " " gap)))
             (let ([gap (slice-text rope cursor (node-start ctx (car kids)))])
               (loop (cdr kids)
                     (node-end ctx (car kids))
                     (string-append acc (if (has-newline? gap) " " gap) (collapsed-text ctx (car kids)))))))])))

(define (collapse-layout ctx c kids start-index)
  (let ([suffix (list-tail kids start-index)]
        [close (close-delim ctx c)])
    (and close
         (not (and (> start-index 0) (comment? ctx (list-ref kids (- start-index 1)))))
         (not (find-first (lambda (k) (uncollapsible? ctx k)) suffix))
         (let* ([start (if (= start-index 0)
                           (node-start ctx c)
                           (node-end ctx (list-ref kids (- start-index 1))))]
                [leading (if (= start-index 0) (open-text ctx c) " ")]
                [parts (map (lambda (k) (collapsed-text ctx k)) suffix)]
                [text (string-append leading (join parts " ") (node-text ctx close))]
                [track (+ start (len leading))])
           (Edit start (node-end ctx c) text track (+ track (len (car parts))))))))

(define (expand-layout ctx c kids start-index)
  (let* ([rope (Ctx-rope ctx)]
         [close (close-delim ctx c)]
         [indent (string-append (line-indentation rope (line-of rope (node-start ctx c))) "  ")]
         [children (map (lambda (k) (node-text ctx k)) (list-tail kids start-index))]
         [indented (lambda (cs) (join (map (lambda (s) (string-append indent s)) cs) "\n"))])
    (and close
         (if (= start-index 0)
             (let* ([open (open-text ctx c)]
                    [start (node-start ctx c)]
                    [text (if (> (length children) 1)
                              (string-append open
                                             (car children)
                                             "\n"
                                             (indented (cdr children))
                                             (node-text ctx close))
                              (string-append open (join children "") (node-text ctx close)))]
                    [track (+ start (len open))])
               (Edit start (node-end ctx c) text track (+ track (len (car children)))))
             (let* ([start (node-end ctx (list-ref kids (- start-index 1)))]
                    [text (string-append "\n" (indented children) (node-text ctx close))]
                    [track (+ start 1 (len indent))])
               (Edit start (node-end ctx c) text track (+ track (len (car children)))))))))

;;@doc
;; `m`: toggle the siblings *after* the current node between one line and one
;; per line. On a top-level form, toggles all of its children.
(define (toggle-layout ctx node)
  (let* ([found (element-and-outer-container ctx node)]
         [c (cond
              [found (cdr found)]
              [(container? ctx (inner ctx node)) (inner ctx node)]
              [else #f])])
    (and c
         (let* ([rope (Ctx-rope ctx)]
                [kids (named-kids c)]
                [start-index (if found (+ 1 (index-of (car found) kids)) 0)])
           (and (< start-index (length kids))
                (let* ([anchor-line (line-of rope (if found (node-end ctx (car found)) (node-end ctx c)))]
                       [start-line (line-of rope (node-start ctx (list-ref kids start-index)))]
                       [edit (if (= start-line anchor-line)
                                 (expand-layout ctx c kids start-index)
                                 (collapse-layout ctx c kids start-index))])
                  (and edit
                       (if found
                           ;; the element itself sits before the edit: keep it selected
                           (Edit (Edit-start edit)
                                 (Edit-end edit)
                                 (Edit-text edit)
                                 (node-start ctx (car found))
                                 (node-end ctx (car found)))
                           edit))))))))

;;;; Insert placements ------------------------------------------------------
;; These return (cons Edit insert-at): the scaffold to insert, and the CHAR
;; offset where Insert mode should start once it's in.

;; Where a new sibling before/after `node` goes: on `node`'s own line, or on a
;; new line when `node` already sits on a line of its own on that side (port
;; of computeAdjacentPlacement). → (list at new-line? indentation)
(define (adjacent-placement ctx node direction)
  (let* ([rope (Ctx-rope ctx)]
         [parent (tsnode-parent node)]
         [start-line (line-of rope (node-start ctx node))]
         [end-line (line-of rope (node-end ctx node))])
    (if (equal? direction 'before)
        (let ([neighbor-line (let ([prev (prev-sibling node)])
                               (cond
                                 [prev (line-of rope (node-end ctx prev))]
                                 [parent (line-of rope (node-start ctx parent))]
                                 [else start-line]))])
          (if (= neighbor-line start-line)
              (list (node-start ctx node) #f "")
              (list (line-start rope start-line) #t (line-indentation rope start-line))))
        (let ([neighbor-line (let ([next (next-sibling node)])
                               (cond
                                 [next (line-of rope (node-start ctx next))]
                                 [parent (line-of rope (node-end ctx parent))]
                                 [else end-line]))])
          (if (= neighbor-line end-line)
              (list (node-end ctx node) #f "")
              (list (line-end rope end-line) #t (line-indentation rope start-line)))))))

;; Insert `body` as a new sibling before/after `node`; `cursor` is the offset
;; inside `body` where typing should start.
(define (sibling-insert ctx node direction body cursor)
  (let* ([placement (adjacent-placement ctx node direction)]
         [at (car placement)]
         [new-line? (cadr placement)]
         [indent (caddr placement)]
         [before? (equal? direction 'before)]
         [prefix (cond
                   [(and new-line? before?) indent]
                   [new-line? (string-append "\n" indent)]
                   [before? ""]
                   [else " "])]
         [suffix (cond
                   [(and new-line? before?) "\n"]
                   [new-line? ""]
                   [before? " "]
                   [else ""])]
         [text (string-append prefix body suffix)]
         [insert-at (+ at (len prefix) cursor)])
    (cons (Edit at at text insert-at insert-at) insert-at)))

;;@doc
;; `i` / `a`: a separator (space or new indented line) before/after the node,
;; with Insert starting right next to the node.
(define (adjacent-insert ctx node direction)
  (sibling-insert ctx node direction "" 0))

;;@doc
;; `(` / `)` etc: a new empty form before/after the node (or at `at` when there
;; is no node), with Insert starting between its brackets.
(define (new-form-insert ctx node direction pair at)
  (let ([body (string-append (car pair) (cadr pair))]
        [inside (len (car pair))])
    (if node
        (sibling-insert ctx node direction body inside)
        (cons (Edit at at body (+ at inside) (+ at inside)) (+ at inside)))))

;;@doc
;; `;`: a new comment line above the node at its indentation, with Insert
;; starting after the comment token.
(define (comment-insert ctx node at)
  (let* ([rope (Ctx-rope ctx)]
         [line (line-of rope (if node (node-start ctx node) at))]
         [indent (line-indentation rope line)]
         [token (string-append (Dialect-comment (Ctx-dialect ctx)) " ")]
         [start (line-start rope line)]
         [insert-at (+ start (len indent) (len token))])
    (cons (Edit start start (string-append indent token "\n") insert-at insert-at) insert-at)))
