;; dialect.scm — which buffers Parry acts on, and how their trees are read.
;;
;; A dialect maps file extensions to a Helix language (whose grammar parses the
;; buffer) plus the node kinds that play each structural role. Commands never
;; hard-code node kinds; they ask the dialect.

(require "helix/editor.scm")
(require "helix/treesitter.scm")

(provide Dialect
         Dialect?
         Dialect-name
         Dialect-extensions
         Dialect-language
         Dialect-containers
         Dialect-brackets
         Dialect-comment
         Dialect-comment-kinds
         Dialect-string-kinds
         define-parry-dialect
         dialect-named
         dialect-for-doc
         dialect-root
         path-extension)

(struct Dialect
        (name extensions language containers brackets comment comment-kinds string-kinds)
        #:transparent)

;; name -> Dialect
(define *dialects* (hash))

;;@doc
;; Register (or replace) a dialect.
;;
;; * extensions    : file extensions (no dot) this dialect applies to
;; * language      : Helix language name used to parse the buffer. When it is
;;                   the buffer's own language, Helix's live tree is used;
;;                   otherwise the buffer is re-parsed with that language.
;; * containers    : node kinds that are bracketed forms
;; * brackets      : (open close) string pairs; the first pair is used by wrap,
;;                   and each pair gets a new-form-before/after key
;; * comment       : line comment token, for new comments
;; * comment-kinds : node kinds that are comments
;; * string-kinds  : node kinds that are string literals
(define (define-parry-dialect name
                              #:extensions (extensions '())
                              #:language (language name)
                              #:containers (containers '())
                              #:brackets (brackets '(("(" ")")))
                              #:comment (comment ";")
                              #:comment-kinds (comment-kinds '("comment"))
                              #:string-kinds (string-kinds '("string")))
  (set! *dialects*
        (hash-insert *dialects*
                     name
                     (Dialect name extensions language containers brackets comment comment-kinds
                              string-kinds))))

;;@doc
;; The extension of `path` without its dot, or #f.
(define (path-extension path)
  (let loop ([i (- (string-length path) 1)])
    (cond
      [(< i 0) #f]
      [(equal? (string-ref path i) #\/) #f]
      [(equal? (string-ref path i) #\.) (substring path (+ i 1) (string-length path))]
      [else (loop (- i 1))])))

(define (find-first pred lst)
  (cond
    [(null? lst) #f]
    [(pred (car lst)) (car lst)]
    [else (find-first pred (cdr lst))]))

;;@doc
;; The dialect registered under `name`, or #f.
(define (dialect-named name)
  (hash-try-get *dialects* name))

;;@doc
;; The dialect for document `doc-id`, by file extension, or #f.
(define (dialect-for-doc doc-id)
  (let* ([path (and doc-id (editor-document->path doc-id))]
         [ext (and path (path-extension path))])
    (and ext
         (find-first (lambda (d) (member ext (Dialect-extensions d))) (hash-values->list *dialects*)))))

;;@doc
;; Root node of `rope`'s parse tree under dialect `d`, or #f.
(define (dialect-root d doc-id rope)
  (let ([tree (if (equal? (editor-document->language doc-id) (Dialect-language d))
                  (document->tree doc-id)
                  (with-handler (lambda (_) #f)
                                (let ([syntax (rope->tssyntax rope (Dialect-language d))])
                                  (and syntax (tssyntax->tree syntax)))))])
    (and tree (tstree->root tree))))
