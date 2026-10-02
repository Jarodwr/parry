;; test.scm — `:parry-self-test`: runs every op against in-memory fixtures
;; (string->rope + rope->tssyntax, no buffer involved) and reports the result
;; in the status line, with details in the Helix log (`PARRY-TEST` lines).

(require "helix/misc.scm")
(require "helix/treesitter.scm")
(require-builtin helix/core/text as text.)
(require "text.scm")
(require "dialect.scm")
(require "tree.scm")
(require "ops.scm")
(require "dialects/fennel.scm")

(provide parry-self-test
         parry-test-results)

;; the dialect the fixtures currently run under
(define *dialect* #f)

(define (ctx-for text-string)
  (let* ([rope (text.string->rope text-string)]
         [syntax (rope->tssyntax rope (Dialect-language *dialect*))])
    (Ctx *dialect* rope (tstree->root (tssyntax->tree syntax)))))

;; index of the `nth` (0-based) occurrence of `needle` in `hay`, or #f
(define (string-index hay needle nth)
  (let ([n (string-length needle)]
        [h (string-length hay)])
    (let loop ([i 0] [seen 0])
      (cond
        [(> (+ i n) h) #f]
        [(equal? (substring hay i (+ i n)) needle) (if (= seen nth) i (loop (+ i 1) (+ seen 1)))]
        [else (loop (+ i 1) seen)]))))

(define (apply-to-string s edit)
  (string-append (substring s 0 (Edit-start edit))
                 (Edit-text edit)
                 (substring s (Edit-end edit) (string-length s))))

;; A fixture: start from `src` with `target` (its `nth` occurrence) selected,
;; run `op`, and expect the buffer to read `want-text` with `want-sel`
;; selected. For moves, `want-text` is #f and only the selection is checked.
;; For ops that should refuse, `want-text` is 'none.
(struct Fixture (name src target nth kind op want-text want-sel))

(define (fixture name src target op want-text want-sel #:nth (nth 0))
  (Fixture name src target nth 'edit op want-text want-sel))

(define (move-fixture name src target op want-sel #:nth (nth 0))
  (Fixture name src target nth 'move op #f want-sel))

(define (run-fixture f)
  (with-handler
   (lambda (err) (list #f (Fixture-name f) (to-string "error:" err)))
   (let* ([src (Fixture-src f)]
          [ctx (ctx-for src)]
          [from (string-index src (Fixture-target f) (Fixture-nth f))]
          [node (and from (current-node ctx from (+ from (string-length (Fixture-target f)))))])
     (cond
       [(not node) (list #f (Fixture-name f) "no node under the fixture selection")]
       [(equal? (Fixture-kind f) 'move)
        (let* ([dest ((Fixture-op f) ctx node)]
               [got (if dest (node-text ctx dest) 'none)])
          (list (equal? got (Fixture-want-sel f)) (Fixture-name f) (to-string "selected" got)))]
       [else
        (let ([edit ((Fixture-op f) ctx node)])
          (cond
            [(not edit)
             (list (equal? (Fixture-want-text f) 'none) (Fixture-name f) "op refused")]
            [else
             (let* ([out (apply-to-string src edit)]
                    [ctx2 (ctx-for out)]
                    [sel (node-at-range ctx2 (Edit-track-start edit) (Edit-track-end edit))]
                    [got-sel (if sel (node-text ctx2 sel) 'none)])
               (list (and (equal? out (Fixture-want-text f)) (equal? got-sel (Fixture-want-sel f)))
                     (Fixture-name f)
                     (to-string "text" (format-text out) "selected" got-sel)))]))]))))

(define (format-text s)
  (to-string "«" s "»"))

(define (on ctx node)
  node)

(define fixtures
  (list
   ;; navigation
   (move-fixture "next sibling" "(a b c)" "b" (lambda (ctx n) (next-sibling n)) "c")
   (move-fixture "prev sibling" "(a b c)" "b" (lambda (ctx n) (prev-sibling n)) "a")
   (move-fixture "no next at last" "(a b c)" "c" (lambda (ctx n) (next-sibling n)) 'none)
   (move-fixture "first child" "(a (b c) d)" "(b c)" first-child "b")
   (move-fixture "last child" "(a (b c) d)" "(a (b c) d)" last-child "d")
   (move-fixture "parent" "(a (b c) d)" "c" parent-form "(b c)")
   (move-fixture "no parent at top" "(a b)\n(c)" "(c)" parent-form 'none)
   (move-fixture "special form child" "(fn f [x] (+ x 1))" "[x]" (lambda (ctx n) (next-sibling n)) "(+ x 1)")
   (move-fixture "string is atomic" "(print \"hi there\")" "hi" on "\"hi there\"")
   (move-fixture "cursor on bracket" "(a [b c])" "[" on "[b c]")
   (move-fixture "quote moves with its form" "(x 'y z)" "y" on "'y")
   (move-fixture "descend through reader macro" "(f #(+ $ 1))" "#" first-child "+")
   (move-fixture "parent includes reader macro" "(f #(+ $ 1))" "$" parent-form "#(+ $ 1)")
   ;; slurp / barf
   (fixture "slurp forward" "(a (b) c)" "b" slurp-forward "(a (b c))" "(b c)")
   (fixture "slurp forward at end" "(a (b c))" "b" slurp-forward 'none 'none)
   (fixture "slurp backward" "(a (b) c)" "b" slurp-backward "((a b) c)" "(a b)")
   (fixture "slurp into special form" "(do (print x) y)" "x" slurp-forward "(do (print x y))" "(print x y)")
   (fixture "barf forward" "(a (b c))" "b" barf-forward "(a (b) c)" "(b)")
   (fixture "barf backward" "(a (b c))" "c" barf-backward "(a b (c))" "(c)")
   (fixture "barf last element" "(a (b))" "b" barf-forward "(a () b)" "()")
   (fixture "slurp refuses a comment" "((a)\n ; note\n b)" "a" slurp-forward 'none 'none)
   ;; raise / wrap / splice / delete
   (fixture "raise" "(a (b c) d)" "c" raise "(a c d)" "c")
   (fixture "raise top level" "(a b)" "(a b)" raise 'none 'none)
   (fixture "wrap" "(a b c)" "b" wrap "(a (b) c)" "(b)")
   (fixture "splice" "(a (b c) d)" "b" splice "(a b c d)" "b")
   (fixture "splice the form itself" "(a (b c) d)" "(b c)" splice "(a b c d)" "b")
   (fixture "splice top level" "(a b)" "a" splice "a b" "a")
   (fixture "splice sequence" "(f [x y])" "x" splice "(f x y)" "x")
   (fixture "splice keeps no reader prefix" "(f #(+ $ 1))" "$" splice "(f + $ 1)" "$")
   (fixture "slurp backward keeps reader prefix" "(a #(b))" "b" slurp-backward "(#(a b))" "#(a b)")
   (fixture "delete middle" "(a b c)" "b" delete-node "(a c)" "c")
   (fixture "delete last" "(a b c)" "c" delete-node "(a b)" "b")
   (fixture "delete only child" "(f (x))" "x" delete-node "(f ())" "()")
   ;; swap
   (fixture "swap next" "(a b c)" "a" (lambda (ctx n) (swap ctx n 'next)) "(b a c)" "a")
   (fixture "swap prev" "(a b c)" "c" (lambda (ctx n) (swap ctx n 'prev)) "(a c b)" "c")
   (fixture "swap keeps the gap" "(f x\n   (g y))" "x" (lambda (ctx n) (swap ctx n 'next)) "(f (g y)\n   x)" "x")
   (fixture "swap forms" "(a (b c) d)" "(b c)" (lambda (ctx n) (swap ctx n 'next)) "(a d (b c))" "(b c)")
   (fixture "no swap past last" "(a b)" "b" (lambda (ctx n) (swap ctx n 'next)) 'none 'none)
   (fixture "no swap with comment" "(a\n ; c\n b)" "a" (lambda (ctx n) (swap ctx n 'next)) 'none 'none)
   ;; layout
   (fixture "expand after node" "(a b c)" "a" toggle-layout "(a\n  b\n  c)" "a")
   (fixture "collapse after node" "(a\n  b\n  c)" "a" toggle-layout "(a b c)" "a")
   (fixture "expand top-level form" "(a b c)" "(a b c)" toggle-layout "(a\n  b\n  c)" "a")
   (fixture "nothing after last" "(a b c)" "c" toggle-layout 'none 'none)
   (fixture "no collapse over comment" "(a\n  ; c\n  b)" "a" toggle-layout 'none 'none)
   ;; insert scaffolds (text after the scaffold is inserted; selection is the
   ;; node at the insert point)
   (fixture "insert after, same line" "(a b)" "a" (lambda (ctx n) (car (adjacent-insert ctx n 'after))) "(a  b)" "b")
   (fixture "new form after" "(a b)" "a" (lambda (ctx n) (car (new-form-insert ctx n 'after '("[" "]") 0))) "(a [] b)" "[]")))

;;@doc
;; Run every fixture; returns (passed failed-names).
;; Run every fixture under dialect `d`; returns (passed failed-names).
(define (run-fixtures d)
  (set! *dialect* d)
  (let loop ([fs fixtures] [passed 0] [failed '()])
    (if (null? fs)
        (list passed (reverse failed))
        (let* ([r (run-fixture (car fs))]
               [ok (car r)]
               [name (to-string (cadr r) "[" (Dialect-name d) "]")])
          (log::info! (to-string "PARRY-TEST" (if ok "ok  " "FAIL") name "--" (caddr r)))
          (loop (cdr fs) (if ok (+ passed 1) passed) (if ok failed (cons name failed)))))))

;;@doc
;; Run every fixture under each Fennel dialect Helix has a grammar for;
;; returns (passed failed-names).
(define (parry-test-results)
  (let loop ([ds (dialects-for-extension "fnl")] [passed 0] [failed '()])
    (if (null? ds)
        (list passed failed)
        (let ([r (run-fixtures (car ds))])
          (loop (cdr ds) (+ passed (car r)) (append failed (cadr r)))))))

;;@doc
;; Run Parry's self-test; details go to the Helix log.
(define (parry-self-test)
  (let* ([r (parry-test-results)]
         [passed (car r)]
         [failed (cadr r)])
    (if (null? failed)
        (set-status! (to-string "parry: all" passed "tests passed"))
        (set-error! (to-string "parry:" (length failed) "failed:" failed)))))
