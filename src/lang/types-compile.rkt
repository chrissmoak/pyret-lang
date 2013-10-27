#lang racket


(provide
  types-compile-pyret
)
(require
  racket/match
  racket/syntax
  "ast.rkt"
  "desugar.rkt" ;; NOTE(dbp 2013-10-25): used locally to be able to write s-list
  )

(define (types-compile-pyret ast)
  (match ast
    [(s-prog s imps block)
     (s-prog s imps
             (types-compile-internal block))]))

;; NOTE(dbp 2013-10-24): Just structural recursion, interesting case is below.
(define (types-compile-internal ast)
  (define tci types-compile-internal)
  (match ast
    [(s-block syntax stmts)
     (s-block syntax (flatten-blocks (map tci stmts)))]
    [(s-var syntax name value)
     (s-var syntax name (tci value))]
    [(s-let syntax name value)
     (s-let syntax name (tci value))]
    [(s-user-block syntax block)
     (s-user-block syntax (tci block))]
    [(s-if-else syntax branches else)
     (s-if-else syntax (map tci branches) (tci else))]
    [(s-if-branch syntax expr body)
     (s-if-branch syntax (tci expr) (tci body))]
    [(s-try syntax body id except)
     (s-try syntax (tci body) id (tci except))]
    [(s-lam syntax typarams args ann doc body check-ignored)
     (s-lam syntax typarams args ann doc (tci body) check-ignored)]
    [(s-method syntax args ann doc body check-ignored)
     (s-method syntax args ann doc (tci body) check-ignored)]
    [(s-data-field syntax name value)
     (s-data-field syntax name (tci value))]
    [(s-extend syntax super fields)
     (s-extend syntax (tci super) (map tci fields))]
    [(s-update syntax super fields)
     (s-update syntax (tci super) (map tci fields))]
    [(s-obj syntax fields)
     (s-obj syntax (map tci fields))]
    [(s-app syntax fun args)
     (s-app syntax (tci fun) (map tci args))]
    [(s-assign syntax id value)
     (s-assign syntax id (tci value))]
    [(s-get-bang syntax obj field)
     (s-get-bang syntax (tci obj) field)]
    [(s-bracket syntax obj field)
     (s-bracket syntax (tci obj) (tci field))]
    [(s-colon-bracket syntax obj field)
     (s-colon-bracket syntax (tci obj) (tci field))]
    [(s-datatype syntax name params variants check)
     (types-compile-datatype ast)]
    [else ast]
))

;; NOTE(dbp 2013-10-24): This is the stuff we actually care about - compiling datatypes
;; into runtime values.
(define (types-compile-datatype ast)
  (match ast
    [(s-datatype s name params variants check)
     (define brander-name (gensym name))
     (s-block s
              (flatten
               (list (s-let s (s-bind s brander-name (a-blank)) (s-app s (s-id s 'brander) (list)))
                     (map (data-variants params brander-name) variants)
                     (make-checker s name brander-name)
                     (s-id s 'nothing)
                    ))
              )]))

(define (make-checker s name brander-name)
  (s-let s (s-bind s name (a-blank)) (s-bracket s (s-id s brander-name) (s-str s "test"))))
(define (apply-brand s brander-name arg)
  (s-app s (s-bracket s (s-id s brander-name) (s-str s "brand")) (list arg)))
(define (meth s args body)
  (s-method s (map (lambda (sym) (s-bind s sym (a-blank))) args) (a-blank) "" body (s-block s empty)))
(define (bind->string m)
  (match m
    [(s-bind s2 m-name _) (s-str s2 (symbol->string m-name))]))

;; NOTE(dbp): these functions are a temporary hack;
;; they are just stripping out parametric annotations, so
;; that code will compile with them present
(define (replace-typarams typarams)
  (define (rt ann)
    (match ann
      [(a-name s name)
       (if (member name typarams)
           (a-any)
           ann)]
      [(a-arrow s args ret)
       (a-arrow s (map rt args) (rt ret))]
      [(a-method s args ret)
       (a-method s (map rt args) (rt ret))]
      [(a-app s name-or-dot params)
       (a-app s (rt name-or-dot) (map rt params))]
      [(a-pred s ann exp) (a-pred s (rt ann) exp)]
      [(a-record s fields) (a-record s (map rt fields))]
      [(a-field s name ann) (a-field s name (rt ann))]
      [_ ann]))
  rt)
(define (replace-typarams-binds typarams)
  (lambda (bind)
    (match bind
      [(s-bind s id ann)
       (s-bind s id ((replace-typarams typarams) ann))]
      [_ bind])))

;; NOTE(dbp 2013-10-25): Right now, this is lifted pretty closely from data desugaring.
;; once the conversion is complete, data desugaring will have these parts removed, so there
;; won't be code duplication (and this comment should be removed at that point).
(define ((data-variants params super-brand) variant)
  (define (make-equals s brander fields)
    (meth s (list 'self 'other)
        (s-app s (s-bracket s (s-id s 'builtins) (s-str s "data-equals"))
          (append
            (list
            (s-id s 'self)
            (s-id s 'other)
            (s-id s brander)
            (desugar-internal (s-list s (map bind->string fields))))))))
  (define (make-match s case-name fields)
    (define call-match-case (gensym (string-append "call-" case-name)))
      (meth s (list 'self 'cases-funs 'else-clause)
        (s-if-else s
         (list
          (s-if-branch s
            (s-app s (s-bracket s (s-id s 'builtins) (s-str s "has-field"))
                   (list (s-id s 'cases-funs) (s-str s case-name)))
            (s-block s
              (list
                (s-let s (s-bind s call-match-case (a-blank))
                       (s-bracket s (s-id s 'cases-funs) (s-str s case-name)))
                (s-app s (s-id s call-match-case)
                       (map (lambda (field-name) (s-bracket s (s-id s 'self)
                                                            (s-str s (symbol->string
                                                                      (s-bind-id field-name)))))
                            fields))))))
         (s-app s (s-id s 'else-clause) (list)))))
  (define strip-param-bind (replace-typarams-binds params))
  (define (apply-constructor s constructor params name obj)
    (s-app s (s-lam s params
                    (list (s-bind s (s-datatype-constructor-self constructor)
                                  (a-blank)))
                    (a-blank)
                    (format "Constructor for ~a" (symbol->string name))
                    (s-datatype-constructor-body constructor)
                    (s-block s empty))
           (list obj)))
  (match variant
    [(s-datatype-variant s name members constructor)
     (define id-members (map s-variant-member-bind members))
     (define (member->constructor-arg m new-id)
        (match m
          [(s-variant-member s member-type (s-bind s2 name ann))
           (define name-str (s-str s2 (symbol->string name)))
           (match member-type
             ['mutable (strip-param-bind (s-bind s2 new-id ann))]
             ['normal (strip-param-bind (s-bind s2 new-id ann))]
             ['cyclic (strip-param-bind (s-bind s2 new-id (a-blank)))]
             [_ (error (format "Bad variant type: ~a" member-type))])]))
     (define (member->field m val)
        (match m
          [(s-variant-member s member-type (s-bind s2 name ann))
           (define name-str (s-str s2 (symbol->string name)))
           (match member-type
             ['mutable (s-mutable-field s2 name-str ann val)]
             ['normal (s-data-field s2 name-str val)]
             ['cyclic (s-once-field s2 name-str ann val)]
             [_ (error (format "Bad variant type: ~a" member-type))])]))
     (define torepr
       (meth s (list 'self)
             (s-app s (s-bracket s (s-id s 'builtins) (s-str s "data-to-repr"))
                    (list (s-id s 'self)
                          (s-str s (symbol->string name))
                          (desugar-internal (s-list s (map bind->string id-members)))))))
     (define equals (make-equals s (make-checker-name name) id-members))
     (define matcher (make-match s (symbol->string name) id-members))
     (define brander-name (gensym name))
     (define base-name (gensym (string-append (symbol->string name) "_base")))
     (define args (map gensym (map s-bind-id id-members)))
     (define constructor-args (map member->constructor-arg members args))
     (define base-obj
       (s-obj s (append (list
                         (s-data-field s (s-str s "_torepr") torepr)
                         (s-data-field s (s-str s "_equals") equals)
                         (s-data-field s (s-str s "_match") matcher)))))
     (define obj
       (s-extend s (s-id s base-name)
                 (map member->field
                      members
                      (map (lambda (id) (s-id s id)) args))))
     (list
           (s-let s (s-bind s base-name (a-blank)) base-obj)
           (s-let s (s-bind s brander-name (a-blank))
                    (s-app s (s-id s 'brander) (list)))
           (make-checker s (make-checker-name name) brander-name)
           (s-let s (s-bind s name (a-blank))
             (s-lam s
                    params
                    constructor-args
                    (a-blank)
                    (format
                     "~a: Creates an instance of ~a"
                     (symbol->string name)
                     (symbol->string name))
                    (s-block s
                      (list
                       (apply-brand s super-brand
                        (apply-brand s brander-name
                         (apply-constructor s constructor params name obj)))))
                    (s-block s empty))))
     ]
    [(s-datatype-singleton-variant s name constructor)
     (define torepr
       (meth s (list 'self)
             (s-str s (symbol->string name))))
     (define brander-name (gensym name))
     (define equals (make-equals s (make-checker-name name) (list)))
     (define matcher (make-match s (symbol->string name) (list)))
     (define base-name (gensym (string-append (symbol->string name) "_base")))
     (define base-obj
       (s-obj s (list
                 (s-data-field s (s-str s "_torepr") torepr)
                 (s-data-field s (s-str s "_equals") equals)
                 (s-data-field s (s-str s "_match") matcher))))
     (list
           (s-let s (s-bind s base-name (a-blank)) base-obj)
           (s-let s (s-bind s brander-name (a-blank))
                    (s-app s (s-id s 'brander) (list)))
           (make-checker s (make-checker-name name)  brander-name)
           (s-let s (s-bind s name (a-blank))
                    (apply-brand s super-brand
                      (apply-brand s brander-name
                        (apply-constructor s constructor params name (s-id s base-name))))))]))