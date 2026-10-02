;; dialects/fennel.scm — Fennel, parsed with Helix's built-in grammar
;; (alexmozaidze/tree-sitter-fennel, see helix/languages.toml).
;;
;; That grammar gives every special form its own node kind, so all 38 kinds
;; that carry `open`/`close` bracket fields are listed as containers.

(require "../dialect.scm")

(define-parry-dialect "fennel"
                      #:extensions '("fnl" "fnlm")
                      #:language "fennel"
                      #:containers '("list" "sequence"
                                            "table"
                                            "list_binding"
                                            "sequence_binding"
                                            "sequence_arguments"
                                            "table_binding"
                                            "table_metadata"
                                            "let_vars"
                                            "iter_body"
                                            "for_iter_body"
                                            "fn_form"
                                            "lambda_form"
                                            "macro_form"
                                            "hashfn_form"
                                            "let_form"
                                            "local_form"
                                            "var_form"
                                            "global_form"
                                            "set_form"
                                            "if_form"
                                            "each_form"
                                            "for_form"
                                            "collect_form"
                                            "icollect_form"
                                            "fcollect_form"
                                            "accumulate_form"
                                            "faccumulate_form"
                                            "case_form"
                                            "case_guard"
                                            "case_guard_or_special"
                                            "case_catch"
                                            "case_try_form"
                                            "match_form"
                                            "match_try_form"
                                            "import_macros_form"
                                            "quote_form"
                                            "unquote_form")
                      #:brackets '(("(" ")") ("[" "]") ("{" "}"))
                      #:comment ";"
                      #:comment-kinds '("comment")
                      #:string-kinds '("string" "string_binding" "docstring"))
