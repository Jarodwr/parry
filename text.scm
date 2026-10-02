;; text.scm — rope helpers, all in CHAR offsets (Helix selections are char
;; indexed; tree-sitter nodes are byte indexed and converted at the edge).

(require-builtin helix/core/text as text.)

(provide byte->char
         char->byte
         text-len
         slice-text
         char-at
         line-of
         line-start
         line-end
         line-indentation
         has-newline?
         trim-range
         join)

(define (byte->char rope b)
  (text.rope-byte->char rope b))

(define (char->byte rope c)
  (text.rope-char->byte rope c))

;; NB: `rope-len-bytes` is wired to len_chars in this build, so lengths are
;; always taken in chars.
(define (text-len rope)
  (text.rope-len-chars rope))

;;@doc
;; The text between CHAR offsets [start, end), as a string.
(define (slice-text rope start end)
  (if (>= start end)
      ""
      (text.rope->string (text.rope->slice rope start end))))

(define (char-at rope c)
  (text.rope-char-ref rope c))

(define (line-of rope c)
  (text.rope-char->line rope c))

(define (line-start rope line)
  (text.rope-line->char rope line))

(define carriage-return (string-ref "\r" 0))

;;@doc
;; CHAR offset of the end of `line`'s content, before its line break.
(define (line-end rope line)
  (if (< (+ line 1) (text.rope-len-lines rope))
      (let* ([next (text.rope-line->char rope (+ line 1))]
             [end (- next 1)])
        (if (and (> end (line-start rope line))
                 (equal? (char-at rope (- end 1)) carriage-return))
            (- end 1)
            end))
      (text-len rope)))

;;@doc
;; The leading whitespace of `line`, to prefix a new line with to match it.
(define (line-indentation rope line)
  (let ([start (line-start rope line)]
        [end (line-end rope line)])
    (let loop ([i start])
      (if (and (< i end)
               (let ([c (char-at rope i)])
                 (or (equal? c #\space) (equal? c #\tab))))
          (loop (+ i 1))
          (slice-text rope start i)))))

(define (has-newline? s)
  (string-contains? s "\n"))

(define (whitespace-at? rope i)
  (char-whitespace? (char-at rope i)))

;;@doc
;; Shrinks [start, end) inward past leading/trailing whitespace. All-whitespace
;; input collapses to the empty range at `end` (port of trimEditedRange).
(define (trim-range rope start end)
  (let* ([lo (let loop ([i start])
               (if (and (< i end) (whitespace-at? rope i)) (loop (+ i 1)) i))]
         [hi (let loop ([i end])
               (if (and (> i lo) (whitespace-at? rope (- i 1))) (loop (- i 1)) i))])
    (if (>= lo hi)
        (cons end end)
        (cons lo hi))))

;;@doc
;; Join a list of strings with `sep`.
(define (join strings sep)
  (string-join strings sep))
