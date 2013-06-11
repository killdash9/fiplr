;;; fiplr.el --- Fuzzy finder for files in a project.

;; Copyright © 2013 Chris Corbyn
;;
;; Author: Chris Corbyn <chris@w3style.co.uk>
;; URL: https://github.com/d11wtq/fiplr
;; Version: 0.1.3
;; Keywords: convenience, usability, project

;; This file is NOT part of GNU Emacs.

;;; --- License

;; Licensed under the same terms as Emacs.

;;; --- Commentary

;; Overview:
;;
;; Fiplr makes it really use to find files anywhere within your entire project
;; by using a cached directory tree and delegating to grizzl.el while you
;; search the tree.
;;
;;   M-x fiplr-find-file
;;
;; By default it looks through all the parent directories of the file you're
;; editing until it finds a .git, .hg, .bzr or .svn directory. You can
;; customize this list of root markers by setting `fiplr-root-markers'.
;;
;;   (setq fiplr-root-markers '(".git" ".svn"))
;;
;; Some files are ignored from the directory tree because they are not text
;; files, or simply to speed up the search. The default list can be
;; customized by setting `fiplr-ignored-globs'.
;;
;;   (setq fiplr-ignored-globs '((directories (".git" ".svn"))
;;                               (files ("*.jpg" "*.png" "*.zip" "*~"))))
;;
;; These globs are used by the UNIX `find' command's -name flag.
;;
;; Usage:
;;
;;   Find files:        M-x fiplr-find-file
;;   Find directories:  M-x fiplr-find-directory
;;   Clear caches:      M-x fiplr-clear-cache
;;
;; For convenience, bind "C-x f" to `fiplr-find-file':
;;
;;   (global-set-key (kbd "C-x f") 'fiplr-find-file)
;;

(require 'cl)
(require 'grizzl)

;;; --- Package Configuration

(defvar *fiplr-file-cache* '()
  "Internal cache used by `fiplr-find-file'.")

(defvar *fiplr-directory-cache* '()
  "Internal cache used by `fiplr-find-directory'.")

(defvar *fiplr-default-root-markers* '(".git" ".svn" ".hg" ".bzr")
  "A list of files/directories to look for that mark a project root.")

(defvar *fiplr-default-ignored-globs*
  '((directories (".git" ".svn" ".hg" ".bzr"))
    (files (".#*" "*~" "*.so" "*.jpg" "*.png" "*.gif" "*.pdf" "*.gz" "*.zip")))
  "An alist of files and directories to exclude from searches.")

(defgroup fiplr nil
  "Configuration options for fiplr - find in project.")

(defcustom fiplr-root-markers *fiplr-default-root-markers*
  "A list of files or directories that are found at the root of a project."
  :type    '(repeat string)
  :group   'fiplr
  :options *fiplr-default-root-markers*)

(defcustom fiplr-ignored-globs *fiplr-default-ignored-globs*
  "An alist of glob patterns to exclude from search results."
  :type    '(alist :key-type symbol :value-type (repeat string))
  :group   'fiplr
  :options *fiplr-default-ignored-globs*)

;;; --- Public Functions

;;;###autoload
(defun fiplr-find-file ()
  "Runs a completing prompt to find a file from the project.
The root of the project is the return value of `fiplr-root'."
  (interactive)
  (fiplr-find-file-in-directory (fiplr-root) fiplr-ignored-globs))

;;;###autoload
(defun fiplr-find-directory ()
  "Runs a completing prompt to find a directory from the project.
The root of the project is the return value of `fiplr-root'."
  (interactive)
  (fiplr-find-directory-in-directory (fiplr-root) fiplr-ignored-globs))

;;;###autoload
(defun fiplr-clear-cache ()
  "Clears the internal caches used by fiplr so the project is searched again."
  (interactive)
  (setq *fiplr-file-cache*      '())
  (setq *fiplr-directory-cache* '()))

;;; --- Private Functions

(defun fiplr-root ()
  "Locate the root of the project by walking up the directory tree.
The first directory containing one of fiplr-root-markers is the root.
If no root marker is found, the current working directory is used."
  (let ((cwd (if (buffer-file-name)
                 (directory-file-name
                  (file-name-directory (buffer-file-name)))
               (file-truename "."))))
    (or (fiplr-find-root cwd fiplr-root-markers)
        cwd)))

(defun fiplr-find-root (path root-markers)
  "Tail-recursive part of project-root."
  (let* ((this-dir (file-name-as-directory (file-truename path)))
         (parent-dir (expand-file-name (concat this-dir "..")))
         (system-root-dir (expand-file-name "/")))
    (cond
     ((fiplr-root-p path root-markers) this-dir)
     ((equal system-root-dir this-dir) nil)
     (t (fiplr-find-root parent-dir root-markers)))))

(defun fiplr-root-p (path root-markers)
  "Predicate to check if the given directory is a project root."
  (let ((dir (file-name-as-directory path)))
    (cl-member-if (lambda (marker)
                    (file-exists-p (concat dir marker)))
                  root-markers)))

(defun fiplr-list-files-shell-command (type path ignored-globs)
  "Builds the `find' command to locate all project files & directories.
PATH is the base directory to recurse from.
IGNORED-GLOBS is an alist with keys 'DIRECTORIES and 'FILES."
  (let* ((type-abbrev
          (lambda (assoc-type)
            (cl-case assoc-type
              ('directories "d")
              ('files "f"))))
         (name-matcher
          (lambda (glob)
            (mapconcat 'identity
                       `("-name" ,(shell-quote-argument glob))
                       " ")))
         (grouped-name-matchers
          (lambda (type)
            (mapconcat 'identity
                       `(,(shell-quote-argument "(")
                         ,(mapconcat (lambda (v) (funcall name-matcher v))
                                     (cadr (assoc type ignored-globs))
                                     " -o ")
                         ,(shell-quote-argument ")"))
                       " ")))
         (matcher
          (lambda (assoc-type)
            (mapconcat 'identity
                       `(,(shell-quote-argument "(")
                         "-type"
                         ,(funcall type-abbrev assoc-type)
                         ,(funcall grouped-name-matchers assoc-type)
                         ,(shell-quote-argument ")"))
                       " "))))
    (mapconcat 'identity
               `("find"
                 ,(shell-quote-argument (directory-file-name path))
                 ,(funcall matcher 'directories)
                 "-prune"
                 "-o"
                 "-not"
                 ,(funcall matcher 'files)
                 "-type"
                 ,(funcall type-abbrev type)
                 "-print")
               " ")))

(defun fiplr-list-files (type path ignored-globs)
  "Expands to a flat list of files/directories found under PATH.
The first parameter TYPE is the symbol 'DIRECTORIES or 'FILES."
  (let* ((prefix (file-name-as-directory (file-truename path)))
         (prefix-length (length prefix))
         (list-string
          (shell-command-to-string (fiplr-list-files-shell-command
                                    type
                                    prefix
                                    ignored-globs))))
    (reverse (reduce (lambda (acc file)
                       (if (> (length file) prefix-length)
                           (cons (substring file prefix-length) acc)
                         acc))
                     (split-string list-string "[\r\n]+" t)
                     :initial-value '()))))

(defun fiplr-report-progress (n total)
  "Show the number of files processed in the message area."
  (when (= 0 (mod n 1000))
    (message (format "Indexed %d/%d" n total))))

(defun fiplr-find-file-in-directory (path ignored-globs)
  "Locate a file under the specified PATH.
If the directory has been searched previously, the cache is used."
  (let ((root-dir (file-name-as-directory path)))
    (unless (assoc root-dir *fiplr-file-cache*)
      (message "Scanning project...")
      (push (cons root-dir
                  (grizzl-make-index (fiplr-list-files 'files
                                                       root-dir
                                                       ignored-globs)
                                     #'fiplr-report-progress))
            *fiplr-file-cache*))
    (let* ((index (cdr (assoc root-dir *fiplr-file-cache*)))
           (file (grizzl-completing-read (format "Find in %s" root-dir)
                                         index)))
      (find-file (concat root-dir file)))))

(provide 'fiplr)

;;; fiplr.el ends here
