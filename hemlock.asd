;; -*- Mode: Lisp; -*-

(proclaim '(optimize (safety 3) (speed 0) (debug 3)))

(defpackage #:hemlock-system
  (:use #:cl)
  (:export #:*hemlock-base-directory* #:iso-8859-1-file))

(in-package #:hemlock-system)

(defclass iso-8859-1-file (asdf:cl-source-file) ())
(defmethod asdf:perform ((o asdf:compile-op) (c iso-8859-1-file))
  ;; Darn.  Can't just CALL-NEXT-METHOD; have to reimplement the
  ;; world.
  (let ((source-file (asdf:component-pathname c))
	(output-file (car (asdf:output-files o c))))
    (multiple-value-bind (output warnings-p failure-p)
	(compile-file source-file :output-file output-file
		      #+sbcl #+sbcl :external-format :iso-8859-1)
      (when warnings-p
	(case (asdf:operation-on-warnings o)
	  (:warn (warn
		  "~@<COMPILE-FILE warned while performing ~A on ~A.~@:>"
		  o c))
	  (:error (error 'compile-warned :component c :operation o))
	  (:ignore nil)))
      (when failure-p
	(case (asdf:operation-on-failure o)
	  (:warn (warn
		  "~@<COMPILE-FILE failed while performing ~A on ~A.~@:>"
		  o c))
	  (:error (error 'compile-failed :component c :operation o))
	  (:ignore nil)))
      (unless output
	(error 'asdf:compile-error :component c :operation o)))))
(defmethod perform ((o asdf:load-source-op) (c iso-8859-1-file))
  ;; likewise, have to reimplement rather than closily extend
  (let ((source (asdf:component-pathname c)))
    (setf (asdf:component-property c 'asdf::last-loaded-as-source)
          (and (load source #+sbcl #+sbcl :external-format :iso-8859-1)
               (get-universal-time)))))

(pushnew :command-bits *features*)
(pushnew :buffered-lines *features*)

(defparameter *hemlock-base-directory*
  (make-pathname :name nil :type nil :version nil
                 :defaults (parse-namestring *load-truename*)))

(defparameter *binary-pathname*
  (make-pathname :directory
                 (append (pathname-directory *hemlock-base-directory*)
                         (list "bin"
                               #+CLISP "clisp"
                               #+CMU   "cmu"
                               #+EXCL  "acl"
                               #+SBCL  "sbcl"
                               #-(or CLISP CMU EXCL SBCL)
                               (string-downcase (lisp-implementation-type))))
                 :defaults *hemlock-base-directory*))

(asdf:defsystem :hemlock
     :pathname #.(make-pathname
 			:directory
                        (pathname-directory *hemlock-base-directory*)
 			:defaults *hemlock-base-directory*)
     :depends-on (clx mcclim)
;;     :source-extension "lisp"
;;     :binary-pathname #.*binary-pathname*
;;     :depends-on (:clim-clx #+NIL :mcclim-freetype)
;;     ;; ehem ..
;;     :initially-do
;;     (progn
;;       ;; try to load clx
;;       (unless (ignore-errors (fboundp (find-symbol "OPEN-DISPLAY" "XLIB")))
;;         (ignore-errors (require :clx))
;;         (ignore-errors (require :cmucl-clx)))
;;       (unless (ignore-errors (fboundp (find-symbol "OPEN-DISPLAY" "XLIB")))
;;         (error "Please provide me with CLX."))
;;       ;; Create binary pathnames
;;       (ensure-directories-exist *binary-pathname*)
;;       (dolist (subdir '("tty" "wire" "user" "core" "clim"))
;;         (ensure-directories-exist
;; 	 (merge-pathnames (make-pathname :directory (list :relative subdir))
;; 			  *binary-pathname*)
;; 	 :verbose t))
;;       ;; Gray Streams
;;       #+CMU
;;       (require :gray-streams)
;;       #+CMU
;;       (setf ext:*efficiency-note-cost-threshold* most-positive-fixnum)
;;       #+CMU
;;       (setf ext:*efficiency-note-limit* 0)
;;       #+CMU
;;       (proclaim '(optimize (c::brevity 3)))
;;       #+CMU
;;       (setf c:*record-xref-info* t)
;;       )
    :components
    ((:module core-1
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src" "core"))
			   *hemlock-base-directory*)
	      :components
	      ((:file "package")
	       ;; Lisp implementation specific stuff goes into one of the next
	       ;; two files.
	       (:file "lispdep" :depends-on ("package"))
	       (:file "hemlock-ext" :depends-on ("package"))

	       (:file "decls" :depends-on ("package")) ; early declarations of functions and stuff
	       (:file "struct" :depends-on ("package"))
	       #+port-core-struct-ed (:file "struct-ed" :depends-on ("package"))
	       (hemlock-system:iso-8859-1-file "charmacs" :depends-on ("package"))
	       (:file "key-event" :depends-on ("package"))))
     (:module bitmap-1
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src" "bitmap"))
			   *hemlock-base-directory*)
	      :depends-on (core-1)
	      :components
	      ((:file "keysym-defs") ; hmm.
	       (:file "bit-stuff") ; input depends on it --amb
	       (:file "hunk-draw"))) ; window depends on it --amb
     (:module core-2
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src" "core"))
			   *hemlock-base-directory*)
	      :depends-on (bitmap-1 core-1)
	      :components
	      ((:file "rompsite")
	       (:file "input")
	       (:file "macros")
	       (:file "line")
	       (:file "ring")
	       (:file "htext1") ; buffer depends on it --amb
	       (:file "buffer")
	       (:file "vars")
	       (:file "interp")
	       (:file "syntax")
	       (:file "htext2")
	       (:file "htext3")
	       (:file "htext4")
	       (:file "files")
	       (:file "search1")
	       (:file "search2")
	       (:file "table")
     
	       (:file "winimage")
	       (:file "window")
	       (:file "screen")
	       (:file "linimage")
	       (:file "cursor")
	       (:file "display")))
     (:module tty-1
 	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "tty"))
			   *hemlock-base-directory*)
 	      :components
 	      (#+port-tty-termcap (:file "termcap")
	       #+port-tty-tty-disp-rt (:file "tty-disp-rt")
	       #+port-tty-tty-display (:file "tty-display")))
     (:module root-1
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src"))
			   *hemlock-base-directory*)
	      :depends-on (core-2 core-1)
	      :components
	      ((:file "pop-up-stream")))
     (:module tty-2
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "tty"))
			   *hemlock-base-directory*)
	      :components
	      (#+port-tty-tty-screen (:file "tty-screen")))
     (:module root-2
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src"))
			   *hemlock-base-directory*)
	      :depends-on (root-1 core-1)
	      :components
	      ((:file "font")
	       (:file "streams")
	       #+port-root-hacks (:file "hacks")
	       (:file "main")
	       (:file "echo")
	       (:file "new-undo")))
     (:module user-1
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src" "user"))
			   *hemlock-base-directory*)
	      :depends-on (root-2 core-1)
	      :components
	      ((:file "echocoms")

	       (:file "command")
	       (:file "kbdmac")
	       (:file "undo")
	       (:file "killcoms")
	       (:file "indent")
	       (:file "searchcoms")
	       (:file "filecoms")
	       (:file "morecoms")
	       (:file "doccoms")
	       (:file "srccom")
	       (:file "group")
	       (:file "fill")
	       (:file "text")

	       (:file "lispmode")
	       #+port-user-ts-buf (:file "ts-buf")
	       #+port-user-ts-stream (:file "ts-stream")
	       #+port-user-eval-server (:file "eval-server")
	       (:file "lispbuf")
	       #+port-user-lispeval (:file "lispeval")
	       #+port-user-spell-rt (:file "spell-rt")
	       #+port-user-spell-corr (:file "spell-corr")
	       #+port-user-spell-aug (:file "spell-aug")
	       #+port-user-spellcoms (:file "spellcoms")

	       (:file "comments")
	       (:file "overwrite")
	       (:file "abbrev")
	       (:file "icom")
	       (:file "defsyn")
	       (:file "scribe")
	       (:file "pascal")
	       (:file "dylan")

	       (:file "edit-defs")
	       (:file "auto-save")
	       (:file "register")
	       (:file "xcoms")
	       #+port-user-unixcoms (:file "unixcoms")
	       #+port-user-mh (:file "mh")
	       (:file "highlight")
	       #+port-user-dired (:file "dired")
	       #+port-user-diredcoms (:file "diredcoms")
	       (:file "bufed")
	       #+port-user-lisp-lib (:file "lisp-lib")
	       (:file "completion")
	       #+port-user-shell (:file "shell")
	       #+port-user-debug (:file "debug")
	       #+port-user-netnews (:file "netnews")
	       #+port-user-rcs (:file "rcs")
	       (:file "dabbrev")
	       (:file "bindings")
	       (:file "bindings-gb")))
     (:module bitmap-2
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src" "bitmap"))
			   *hemlock-base-directory*)
	      :depends-on (user-1 core-1)
	      :components
	      ((:file "rompsite")
	       (:file "input")
	       (:file "bit-screen")
	       (:file "bit-display")
	       (:file "pop-up-stream")))
     (:module clim-1
	      :pathname #.(merge-pathnames
			   (make-pathname
			    :directory '(:relative "src" "clim"))
			   *hemlock-base-directory*)
	      :depends-on (bitmap-2 core-1)
	      :components
	      ((:file "patch")
	       (:file "foo")
	       #+port-clim-exp-syntax (:file "exp-syntax")))))
