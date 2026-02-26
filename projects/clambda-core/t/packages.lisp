;;;; t/packages.lisp — Test package for clambda-core

(defpackage #:clambda-core/tests
  (:use #:cl #:clambda)
  (:export #:run-smoke-test))
