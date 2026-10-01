;;; picard-mode-test.el --- Tests for picard-mode  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   emacs --batch -Q -L . -l test/picard-mode-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; Tests that need tree-sitter skip themselves when Emacs lacks it or the
;; taggerscript grammar cannot be loaded.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'picard-mode)
(require 'picard-data)
(require 'picard-flymake)
(require 'picard-eldoc)

;; Loaded only when tree-sitter and the grammar are available.
(declare-function picard-ts-mode "picard-ts-mode" ())

(defconst picard-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root holding the package sources.")

;;;; Autoloads

(defun picard-test--autoload-forms ()
  "Return the forms of the autoloads generated from the package sources."
  (let* ((dir (file-name-as-directory (make-temp-file "picard-test" t)))
         (file (expand-file-name "picard-mode-autoloads.el" dir)))
    (unwind-protect
        (progn
          (dolist (src (directory-files picard-test--root t "\\.el\\'"))
            (copy-file src dir))
          (let ((inhibit-message t))
            (loaddefs-generate dir file))
          (with-temp-buffer
            (insert-file-contents file)
            (let (forms form)
              (while (setq form (ignore-errors (read (current-buffer))))
                (push form forms))
              (nreverse forms))))
      (delete-directory dir t))))

(defun picard-test--mode-after-autoloads (grammar-available)
  "Evaluate the package autoloads and return (MODE . REMAP) for a .picard file.
GRAMMAR-AVAILABLE is what `treesit-language-available-p' reports."
  (let ((auto-mode-alist nil)
        (major-mode-remap-alist nil)
        (forms (picard-test--autoload-forms)))
    (cl-letf (((symbol-function 'treesit-language-available-p)
               (lambda (&rest _) grammar-available)))
      (dolist (form forms)
        ;; Only the registration forms matter here; skip the definitions
        ;; so the loaded functions are left alone.
        (when (memq (car-safe form) '(add-to-list when))
          (eval form t))))
    (cons (assoc-default "x.picard" auto-mode-alist #'string-match)
          (assq 'picard-mode major-mode-remap-alist))))

(ert-deftest picard-test-autoloads-fall-back-without-grammar ()
  (skip-unless (fboundp 'loaddefs-generate))
  (let ((result (picard-test--mode-after-autoloads nil)))
    (should (eq (car result) 'picard-mode))
    (should-not (cdr result))))

(ert-deftest picard-test-autoloads-remap-with-grammar ()
  (skip-unless (fboundp 'loaddefs-generate))
  (let ((result (picard-test--mode-after-autoloads t)))
    (should (eq (car result) 'picard-mode))
    (should (equal (cdr result) '(picard-mode . picard-ts-mode)))))

(ert-deftest picard-test-install-grammar-autoloaded ()
  (skip-unless (fboundp 'loaddefs-generate))
  (should (cl-some (lambda (form)
                     (and (eq (car-safe form) 'autoload)
                          (equal (cadr form) ''picard-ts-mode-install-grammar)))
                   (picard-test--autoload-forms))))

;;;; Font lock and syntax

(ert-deftest picard-test-escape-face-exists ()
  (should (facep picard--font-lock-escape-face)))

(ert-deftest picard-test-long-noop-closes-across-chunks ()
  (with-temp-buffer
    (insert "$noop(\n")
    (dotimes (_ 200) (insert "a comment line (with \\) parens)\n"))
    (insert ")\n$set(a,b)\n")
    (picard-mode)
    ;; Propertize in small steps, as jit-lock does.
    (let ((pos 1))
      (while (< pos (point-max))
        (syntax-propertize pos)
        (setq pos (min (point-max) (+ pos 120)))))
    (should (nth 4 (syntax-ppss 500)))
    (should-not (nth 4 (syntax-ppss (- (point-max) 3))))))

;;;; Flymake

(ert-deftest picard-test-count-args ()
  (with-temp-buffer
    (dolist (case '(("$f()" . 0) ("$f( )" . 1) ("$f(,)" . 2)
                    ("$f(a,$g(b,c),\\,d)" . 3)))
      (erase-buffer)
      (insert (car case))
      (should (equal (picard-flymake--count-args-traditional 3) (cdr case)))))
  (with-temp-buffer
    (insert "$f")
    (should-not (picard-flymake--count-args-traditional 2))))

(ert-deftest picard-test-escaped-delimiters-balanced ()
  (with-temp-buffer
    (insert "$set(x,\\(a\\%)\n")
    (should-not (picard-flymake--scan-delimiter-balance (current-buffer)))))

(ert-deftest picard-test-while-condition-spaces ()
  (with-temp-buffer
    (insert "$while( %a%,x)\n")
    (should (= 1 (length (picard-flymake--scan-whitespace-args
                          (current-buffer)))))))

;;;; Eldoc

(ert-deftest picard-test-show-all-with-flymake ()
  (with-temp-buffer
    (insert "$if(%artist%,$upper(x))")
    (picard-mode)
    (goto-char 6)
    (picard-eldoc-show-all)
    (with-current-buffer (help-buffer)
      (should (string-match-p "%artist%" (buffer-string))))))

(ert-deftest picard-test-since-note ()
  (should (string-suffix-p
           "(since Picard 3.0)"
           (picard-eldoc--make-signature
            "$get_new" (picard-function-info "$get_new")))))

;;;; Data

(ert-deftest picard-test-data-shape ()
  (dolist (entry picard-builtin-functions)
    (let* ((info (cdr entry))
           (min (plist-get info :min-args))
           (max (plist-get info :max-args))
           (args (plist-get info :args)))
      (should (string-prefix-p "$" (car entry)))
      (should (stringp (plist-get info :doc)))
      (should (or (= max -1) (<= min max)))
      ;; Every argument Picard can accept has a name.
      (should (>= (length args) (if (= max -1) min max))))))

(ert-deftest picard-test-performer-arity ()
  (let ((info (picard-function-info "$performer")))
    (should (= (plist-get info :min-args) 0))
    (should (= (plist-get info :max-args) 2))))

;;;; Tree-sitter

(ert-deftest picard-test-ts-indent-one-tab-per-level ()
  (skip-unless (and (fboundp 'treesit-language-available-p)
                    (treesit-language-available-p 'taggerscript)))
  (require 'picard-ts-mode)
  (with-temp-buffer
    (insert "$if(%artist%,\n$upper(\n%title%\n),\nx\n)\n")
    (picard-ts-mode)
    (indent-region (point-min) (point-max))
    (should (equal (buffer-string)
                   "$if(%artist%,\n\t$upper(\n\t\t%title%\n\t),\n\tx\n)\n"))))

(provide 'picard-mode-test)
;;; picard-mode-test.el ends here
