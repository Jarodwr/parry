;; dialect.scm — which buffers Parry acts on, and how their trees are read.
;;
;; A dialect maps file extensions to a Helix language (whose grammar parses the
;; buffer) plus the node kinds that play each structural role. Commands never
;; hard-code node kinds; they ask the dialect.

(require "helix/editor.scm")
(require "helix/treesitter.scm")
(require-builtin helix/core/text as text.)

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
         dialects-for-extension
         language-available?
         dialect-root
         path-extension)

(struct Dialect
        (name extensions language containers brackets comment comment-kinds string-kinds)
        #:transparent)

;; name -> Dialect
(define *dialects* (hash))
;; names in registration order: for an extension, the first dialect whose
;; language Helix can parse wins
(define *order* '())

;;@doc
;; Register (or replace) a dialect. Several dialects may claim an extension;
;; the first registered whose language Helix has a grammar for is used.
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
  (unless (hash-contains? *dialects* name)
    (set! *order* (append *order* (list name))))
  (set! *dialects*
        (hash-insert *dialects*
                     name
                     (Dialect name extensions language containers brackets comment comment-kinds
                              string-kinds))))

;; language name -> #t/#f, filled on first use
(define *available* (hash))

;;@doc
;; Whether Helix has a grammar for language `name` (e.g. "fennel-sexp", which
;; only some builds add). Checked once per language.
(define (language-available? name)
  (if (hash-contains? *available* name)
      (hash-ref *available* name)
      (let ([ok (with-handler (lambda (_) #f)
                              (and (rope->tssyntax (text.string->rope "") name) #t))])
        (set! *available* (hash-insert *available* name ok))
        ok)))

;;@doc
;; Dialects for file extension `ext` whose language Helix can parse, in
;; registration order.
(define (dialects-for-extension ext)
  (filter (lambda (d) (and (member ext (Dialect-extensions d)) (language-available? (Dialect-language d))))
          (map (lambda (name) (hash-ref *dialects* name)) *order*)))

;;@doc
;; The extension of `path` without its dot, or #f.
(define (path-extension path)
  (let loop ([i (- (string-length path) 1)])
    (cond
      [(< i 0) #f]
      [(equal? (string-ref path i) #\/) #f]
      [(equal? (string-ref path i) #\.) (substring path (+ i 1) (string-length path))]
      [else (loop (- i 1))])))

;;@doc
;; The dialect registered under `name`, or #f.
(define (dialect-named name)
  (hash-try-get *dialects* name))

;;@doc
;; The dialect for document `doc-id`: the first registered for its file
;; extension whose language Helix can parse, or #f.
(define (dialect-for-doc doc-id)
  (let* ([path (and doc-id (editor-document->path doc-id))]
         [ext (and path (path-extension path))]
         [ds (if ext (dialects-for-extension ext) '())])
    (if (null? ds) #f (car ds))))

;;@doc
;; Root node of `rope`'s parse tree under dialect `d`, or #f.
(define (dialect-root d doc-id rope)
  (let ([tree (if (equal? (editor-document->language doc-id) (Dialect-language d))
                  (document->tree doc-id)
                  (with-handler (lambda (_) #f)
                                (let ([syntax (rope->tssyntax rope (Dialect-language d))])
                                  (and syntax (tssyntax->tree syntax)))))])
    (and tree (tstree->root tree))))
