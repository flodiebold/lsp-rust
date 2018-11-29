;;; lsp-rust.el --- Rust support for lsp-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2017 Vibhav Pant <vibhavp@gmail.com>

;; Author: Vibhav Pant <vibhavp@gmail.com>
;; Version: 1.0
;; Package-Requires: ((emacs "25") (lsp-mode "3.0") (rust-mode "0.3.0") (dash "1.0") (markdown-mode "2.3"))
;; Keywords: rust
;; URL: https://github.com/emacs-lsp/lsp-rust

;;; Commentary:

;; lsp-mode client for the Rust Language Server (RLS).
;; See https://github.com/rust-lang-nursery/rls
;;
;; # Setup
;;
;; You can load lsp-rust after lsp-mode by adding the following to your init
;; file:
;;
;;    (with-eval-after-load 'lsp-mode
;;      (require 'lsp-rust)
;;      (add-hook 'rust-mode-hook #'lsp-rust-enable))
;;
;; You may want to customize the command that lsp-rust uses to launch the RLS.
;; See `lsp-rust-rust-command'.

;;; Code:

;; (require 'lsp-mode)
(require 'lsp)
(require 'cl-lib)
(require 'json)
(require 'font-lock)
(require 'xref)
(require 'dash)
(require 'ht)
(require 'markdown-mode)

(defvar lsp-rust--use-rust-analyzer nil)
(defvar lsp-rust--config-options (make-hash-table))
(defvar lsp-rust--diag-counters (make-hash-table))
(defvar lsp-rust--running-progress (make-hash-table))

(defcustom lsp-rust-rust-analyzer-command '("ra_lsp_server")
  ""
  :type '(repeat (string)))

(defcustom lsp-rust-rls-command '("rls")
  "The command used to launch the RLS.

This should be a list of strings, the first string being the
executable, and the remaining strings being the arguments to this
executable.

If this variable is nil, lsp-rust will try to use the RLS located
at the environment variable RLS_ROOT, if set."
  :type '(repeat (string)))

(defun lsp-rust-explain-error-at-point ()
  "Explain the error at point.
The explaination comes from 'rustc --explain=ID'."
  (interactive)
  (unless (memq (bound-and-true-p flycheck-checker) '(lsp-ui lsp))
    (user-error "You need to enable lsp-ui-flycheck"))
  (-if-let* ((current-window (selected-window))
             (id (-> (car (flycheck-overlay-errors-at (point)))
                     (flycheck-error-id))))
      (pop-to-buffer
       (with-current-buffer (get-buffer-create "*rustc error*")
         (let ((buffer-read-only nil))
           (erase-buffer)
           (insert (shell-command-to-string (concat "rustc --explain=" id))))
         (if (fboundp 'markdown-view-mode)
             (markdown-view-mode)
           (markdown-mode))
         (setq-local markdown-fontify-code-blocks-natively t)
         (setq-local markdown-fontify-code-block-default-mode 'rust-mode)
         (setq-local kill-buffer-hook (lambda nil
                                        (quit-restore-window)
                                        (when (window-live-p current-window)
                                          (select-window current-window))))
         (setq header-line-format
               (concat (propertize " rustc" 'face 'error)
                       (propertize " " 'display
                                   `(space :align-to (- right-fringe ,(1+ (length id)))))
                       (propertize id 'face 'error)))
         (markdown-toggle-markup-hiding 1)
         (font-lock-ensure)
         (goto-char 1)
         (current-buffer)))
    (message "explain-error: No error at point")))

(defun lsp-rust-find-implementations ()
  "List all implementation blocks for a trait, struct, or enum at point."
  (interactive)
  (let* ((impls (lsp--send-request (lsp--make-request
                                    "rustDocument/implementations"
                                    (lsp--text-document-position-params))))
         (items (lsp--locations-to-xref-items impls)))
    (if items
        (xref--show-xrefs items nil)
      (message "No implementation found for: %s" (thing-at-point 'symbol t)))))

(defun lsp-rust--rls-command ()
  "Return the command used to start the RLS for defining the LSP Rust client."
  (or lsp-rust-rls-command
      (-when-let (rls-root (getenv "RLS_ROOT"))
        `("cargo" "+nightly" "run" "--quiet"
          ,(concat "--manifest-path="
                   (concat
                    (file-name-as-directory (expand-file-name rls-root))
                    "Cargo.toml"))
          "--release"))))

(defun lsp-rust--ra-command ()
  "Return the command used to start the RA for defining the LSP Rust client."
  lsp-rust-rust-analyzer-command)

(defun lsp-rust--get-root ()
  (let (dir)
    (unless
        (ignore-errors
          (let* ((output (shell-command-to-string "cargo metadata --no-deps --format-version 1"))
                 (js (json-read-from-string output)))
            (setq dir (cdr (assq 'workspace_root js)))))
      (error "Couldn't find root for project at %s" default-directory))
    dir))

(define-inline lsp-rust--as-percent (fraction)
  (inline-quote (format "%d%%" (round (* ,fraction 100)))))

(defconst lsp-rust--handlers
  '(("window/progress" .
     (lambda (workspace progress)
       (let ((id (gethash "id" progress))
	     (message (gethash "message" progress))
	     (percentage (gethash "percentage" progress))
	     (title (gethash "title" progress))
	     (workspace-progress (gethash workspace lsp-rust--running-progress)))
	 (if (gethash "done" progress)
	     (setq workspace-progress (delete id workspace-progress))
	   (delete-dups workspace-progress)
	   (push id workspace-progress))
	 (puthash workspace workspace-progress lsp-rust--running-progress)
	 (setq lsp-status
	       (if workspace-progress
		   (cond
		    ((numberp percentage) (lsp-rust--as-percent percentage))
		    (message (format "(%s)" message))
		    (title (format "(%s)" (downcase title))))
		 nil)))))
    ;; From rls-vscode:
    ;; FIXME these are legacy notifications used by RLS ca jan 2018.
    ;; remove once we're certain we've progress on.
    ("rustDocument/diagnosticsBegin" . (lambda (_w _p)))
    ("rustDocument/diagnosticsEnd" .
     (lambda (w _p)
       (when (<= (cl-decf (gethash w lsp-rust--diag-counters 0)) 0)
         (setq lsp-status nil))))
    ("rustDocument/beginBuild" .
     (lambda (w _p)
       (cl-incf (gethash w lsp-rust--diag-counters 0))
       (setq lsp-status "(building)")))))

(defconst lsp-rust--ra-notification-handlers
  '(("m/publishDecorations" . (lambda (_w _p)))))

(defconst lsp-rust--ra-action-handlers
  '(("ra-lsp.applySourceChange" .
     (lambda (p) (lsp-rust--handle-ra-lsp-apply-source-change p)))))

(defun lsp-rust--apply-text-document-edit (edit)
  "Like lsp--apply-text-document-edit, but it allows nil version."
  (let* ((ident (gethash "textDocument" edit))
         (filename (lsp--uri-to-path (gethash "uri" ident)))
         (version (gethash "version" ident)))
    (with-current-buffer (find-file-noselect filename)
      (message "version %s vs %s" version (lsp--cur-file-version))
      (when (or (not version) (= version (lsp--cur-file-version)))
        (message "applying edits")
        (lsp--apply-text-edits (gethash "edits" edit))))))

(defun lsp-rust--handle-ra-lsp-apply-source-change (p)
  ;; TODO fileSystemEdits
  ;; TODO cursorPosition
  (--each (ht-get (car (ht-get p "arguments")) "sourceFileEdits")
    (lsp-rust--apply-text-document-edit it)))

(defun lsp-rust--render-string (str)
  (condition-case nil
      (with-temp-buffer
	(delay-mode-hooks (rust-mode))
	(insert str)
	(font-lock-ensure)
	(buffer-string))
    (error str)))

(defun lsp-rust--initialize-client (client)
  (mapcar #'(lambda (p) (lsp-client-on-notification client (car p) (cdr p)))
          lsp-rust--handlers)
  (mapcar #'(lambda (p) (lsp-client-on-action client (car p) (cdr p)))
	        lsp-rust--action-handlers)
  (lsp-provide-marked-string-renderer client "rust" #'lsp-rust--render-string))

;; (lsp-define-stdio-client lsp-rust "rust" #'lsp-rust--get-root nil
;; 			 :command-fn #'lsp-rust--rls-command
;; 			 :initialize #'lsp-rust--initialize-client)

(lsp-register-client
 (make-lsp-client
  :new-connection (lsp-stdio-connection #'lsp-rust--rls-command)
  :notification-handlers (ht<-alist lsp-rust--handlers)
  :major-modes '(rust-mode toml-mode)
  :server-id 'rust-rls))

(lsp-register-client
 (make-lsp-client
  :new-connection (lsp-stdio-connection #'lsp-rust--ra-command)
  :notification-handlers (ht<-alist lsp-rust--ra-notification-handlers)
  :action-handlers (ht<-alist lsp-rust--ra-action-handlers)
  :major-modes '(rust-mode)
  :ignore-messages '("m/publishDecorations")
  :server-id 'rust-ra))

(defun lsp-rust--set-configuration ()
  (lsp--set-configuration `(:rust ,lsp-rust--config-options)))

(add-hook 'lsp-after-initialize-hook 'lsp-rust--set-configuration)

(defun lsp-rust-set-config (name option)
  "Set a config option in the rust lsp server."
  (puthash name option lsp-rust--config-options))

(defun lsp-rust-set-build-lib (build)
  "Enable(t)/Disable(nil) building the lib target."
  (lsp-rust-set-config "build_lib" build))

(defun lsp-rust-set-build-bin (build)
  "The bin target to build."
  (lsp-rust-set-config "build_bin" build))

(defun lsp-rust-set-cfg-test (val)
  "Enable(t)/Disable(nil) #[cfg(test)]."
  (lsp-rust-set-config "cfg_test" val))

(defun lsp-rust-set-goto-def-racer-fallback (val)
  "Enable(t)/Disable(nil) goto-definition should use racer as fallback."
  (lsp-rust-set-config "goto_def_racer_fallback" val))

(provide 'lsp-rust)
;;; lsp-rust ends here
