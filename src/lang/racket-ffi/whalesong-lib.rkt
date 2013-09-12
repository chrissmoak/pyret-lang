#lang whalesong

; Miscellaneous whalesong functions

(require
   (except-in "../runtime.rkt" raise)
   "../ffi-helpers.rkt")

(provide (rename-out [read-sexpr-pfun read-sexpr]
                     [read-sexprs-pfun read-sexpr-list]))

; read-sexpr: Convert an sexpr string into nested Pyret lists.
;             Symbols are wrapped in ("symbol" ***).
(define read-sexpr-pfun
  (p:pλ (pyret-str)
  "Take a string as input, and parse it into an s-expression.
Each s-expression is a number, symbol, string, or a list of
s-expressions surrounded by parenthesis and separated by whitespace.
Parenthesized lists are converted into Pyret lists, and strings
are each converted into a list [\"string\", <the-string>].

For example, read-sexpr(\"((-13 +14 88.8) cats ++ \\\"dogs\\\")\") will return
  [[-13, 14, 88.8], \"cats\", \"++\", [\"string\", \"dogs\"]]
"
  (ffi-wrap (sexpr->list (parse-expr (ffi-unwrap pyret-str))))))

(define read-sexprs-pfun
  (p:pλ (pyret-str)
    "Read a sequence of s-expressions from a string. See read-sexpr."
    (ffi-wrap (sexpr->list (parse-exprs (ffi-unwrap pyret-str))))))

(define (sexpr->list x)
  (cond [(list? x)   (map sexpr->list x)]
        [(symbol? x) (symbol->string x)]
        [(string? x) (list "string" x)]
        [x           x]))

(define (parse-expr str)
  (parse (action first (seq expr eof)) str))

(define (parse-exprs str)
  (parse (action first (seq exprs eof)) str))

#| Top-down Parsing |#

(define-struct succ (value input) #:transparent)
(define-struct fail () #:transparent)
(define-struct buffer (str index) #:transparent)

(define (parse x str)
  (define (raise-read-sexpr-exn str)
    (raise (p:pyret-error
  	        p:dummy-loc "read-sexpr"
            (format "read-sexpr: Invalid s-expression: \"~a\"" str))))
  (let [[answer (x (buffer str 0))]]
    (if (succ? answer)
        (succ-value answer)
        (raise-read-sexpr-exn str))))

(define (eof? input)
  (= (string-length (buffer-str input))
     (buffer-index input)))

(define PRINT #f)
(define (debug-printf template . args)
  (when PRINT
    (apply printf (cons template args))))
(define (mk-print-wrapper str f)
  (λ (input)
    (debug-printf "Entering ~a with input ~a\n" str input)
    (f input)))
(define (id-wrapper str) (mk-print-wrapper str (λ (x) x)))

(define eof
  (mk-print-wrapper "eof"
    (λ (input)
      (if (eof? input)
          (succ (void) input)
          (fail)))))

(define (char pred?)
  (λ (input)
    (debug-printf "char ~a ~a" (char-whitespace? #\2) (string-ref (buffer-str input) (buffer-index input)))
    (if (eof? input)
        (fail)
        (let [[c (string-ref (buffer-str input)
                             (buffer-index input))]]
          (if (pred? c)
              (succ (make-string 1 c)
                    (buffer (buffer-str input)
                            (+ (buffer-index input) 1)))
              (fail))))))

(define (star x [result (list)])
  (mk-print-wrapper "star"
  (λ (input)
    (if (eof? input)
        (succ result input)
        (let [[answer (x input)]]
          (if (succ? answer)
              ((star x (append result (list (succ-value answer))))
               (succ-input answer))
              (succ result input)))))))

(define (option . xs)
  (mk-print-wrapper "option"
  (λ (input)
    (if (empty? xs)
        (fail)
        (let [[answer ((car xs) input)]]
          (if (succ? answer)
              answer
              ((apply option (cdr xs)) input)))))))

(define (seq . xs)
  (mk-print-wrapper "seq"
  (λ (input)
    (if (empty? xs)
        (succ (list) input)
        (let [[answer ((car xs) input)]]
          (if (succ? answer)
              (let [[answers ((apply seq (cdr xs))
                              (succ-input answer))]]
                (if (succ? answers)
                    (succ
                     (cons (succ-value answer)
                           (succ-value answers))
                     (succ-input answers))
                    (fail)))
              (fail)))))))

(define (action f x)
  (mk-print-wrapper "action"
  (λ (input)
    (let [[answer (x input)]]
      (if (succ? answer)
          (succ (f (succ-value answer)) (succ-input answer))
          (fail))))))

(define (plus x)
  (mk-print-wrapper "plus"
  (action (λ (x) (cons (first x) (second x)))
          (seq x (star x)))))

(define-syntax-rule (tie-knot x)
  (mk-print-wrapper "tie-knot"
  (λ (input) (x input))))


#| Reading S-expressions |#

(define whitespace
  (action (id-wrapper "whitespace")
    (star (char char-whitespace?))))

(define num
  (action (mk-print-wrapper "num" (λ (x)
            (let [[sign (first x)]
                  [digits (second x)]]
              (* (if (equal? sign "-") -1 1)
                 (string->number (apply string-append digits))))))
          (seq (option (char (λ (c) (eq? c #\-)))
                       (char (λ (c) (eq? c #\+)))
                       (seq))
               (plus (char (λ (c) (or (char-numeric? c)
                                      (eq? c #\.))))))))

(define string
  (action (mk-print-wrapper "string" (λ (x) (apply string-append (second x))))
          (seq (char (λ (c) (eq? c #\")))
               (star (char (λ (c) (not (eq? c #\")))))
               (char (λ (c) (eq? c #\"))))))

(define symbol-chars (string->list "~!@#$%^&*-=_+?,./;:<>|"))
(define (symbol-char? c)
  (or (char-alphabetic? c)
      (char-numeric? c)
      (member c symbol-chars)))
(define symbol
  (action (mk-print-wrapper "symbol" (λ (x) (string->symbol (apply string-append x))))
          (plus (char symbol-char?))))

(define (token x)
  (action (mk-print-wrapper "token" (λ (x) (second x)))
          (seq whitespace
               x
               whitespace)))

(define exprs
  (action (id-wrapper "exprs") (star (token (tie-knot expr)))))

(define parens
  (action (mk-print-wrapper "parens" (λ (x) (second x)))
          (seq (token (char (λ (c) (eq? c #\())))
               exprs
               (token (char (λ (c) (eq? c #\))))))))

(define expr
  (action (id-wrapper "expr") (token (option parens string num symbol))))

(define (f x)
  (parse-expr x))

#| Tests |# #|
(parse num "3848a9")
(parse string "\"some chars\"blarg")
(parse symbol "symbool gogo")
(parse-expr "3")
(parse-expr "()")
(parse-expr "(1 2)")
(parse-expr "(( ()394  qqv?#%^fu8   ++ \"st ring\")(  ))")
(parse-expr "+")
(parse-expr "++")
(parse-expr "-385")
(parse-expr "3.48")
(parse-expr "+3.48")
(parse-exprs "1 2 3")
(parse-exprs "- 385")
(parse-exprs "(_) (3 4)")
|#