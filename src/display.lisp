;;;
;;;   Copyright (C) 2013 Clozure Associates
;;;

(in-package :hemlock)

;; Functions used by the IDE display code.

(defmacro with-display-context (view &body body)
  `(let* ((hi::*current-view* ,view)
	  (hi::*current-buffer* (hemlock-view-buffer hi::*current-view*)))
     ,@body))


;; User variable.  Maps symbol categories (see compute-symbol-category) to color specs
(defvar *lisp-code-colors* '((:string :blue)
			     (:comment :brown)
			     (:double-comment :orange)
			     (:triple-comment :red)
			     (:system-symbol (0 .5 0 1))
			     (:definition  (1 0 1 1))
			     (:keyword :purple)))


;; Hemlock style would be more to pass in two marks that get moved to the bounds, leave the absolute position
;; stuff to caller.  We could keep two marks for this purpose in the view, so don't have to cons them each time.
(defun hemlock:paren-matching-bounds ()
  "Compute the positions of the two characters to be shown as matching parens"
  (let ((point (current-point)))
    (cond ((eql (next-character point) #\()
           (pre-command-parse-check point)
           (when (valid-spot point t)
             (with-mark ((temp point))
               (when (list-offset temp 1)
                 (values (mark-absolute-position point)
                         (1- (mark-absolute-position temp)))))))
          ((eql (previous-character point) #\))
           (pre-command-parse-check point)
           (when (valid-spot point nil)
             (with-mark ((temp point))
               (when (list-offset temp -1)
                 (values (mark-absolute-position temp)
                         (1- (mark-absolute-position point))))))))))


;; Return nil to use the default Cocoa selection, which will be word for double-click, line for triple.
(defun hemlock:selection-for-click (mark paragraph-mode-p)
  ;; Handle lisp mode specially, otherwise just go with default Cocoa behavior
  (when (string= (buffer-major-mode (mark-buffer mark)) "Lisp")
    (unless paragraph-mode-p
      (let ((region (word-region-at-mark mark)))
        (when region
          (return-from selection-for-click region))))
    (pre-command-parse-check mark)
    (form-region-at-mark mark)))

(defun hemlock:move-point-for-click (buffer index)
  (let* ((point (buffer-point buffer))
         (mark (and (%buffer-region-active-p buffer) (buffer-mark buffer))))
    (setf (hi::buffer-region-active buffer) nil)
    (unless (eql (mark-absolute-position point) index)  ;; if point is already at target, leave mark alone
      (if (and mark (eql (mark-absolute-position mark) index))
        (move-mark mark point)
        (push-new-buffer-mark point))
      (move-to-absolute-position point index))))


(defun shortest-package-name (package)
  (let* ((name (package-name package))
         (len (length name)))
    (dolist (nick (package-nicknames package) name)
      (let* ((nicklen (length nick)))
        (if (< nicklen len)
          (setq name nick len nicklen))))))

(defun hemlock:update-current-package (&optional pkg)
  (when (equalp (buffer-major-mode (current-buffer)) "Lisp")
    (unless pkg
      (setq pkg (or (package-at-mark (current-point))
                    (value default-package))))
    (when pkg
      (let* ((name (if (packagep pkg) (package-name pkg) (string pkg)))
             (curname (value current-package)))
        (when (setq pkg (find-package name))
          (setq name (shortest-package-name pkg)))
        (if (or (null curname)
                (not (string= curname name)))
          (setf (value current-package) name))))))

;; advance to next symbol, ignoring form boundaries, strings, etc.
(defun %scan-to-symbol (mark)
  (loop while (%scan-to-form mark t)
    do (unless (test-char (next-character mark) :lisp-syntax (or :string-quote :open-paren :close-paren))
         (return mark))
    do (mark-after mark)))

;; Advance to next atom, ignoring open parens (but not close parens, unlike above).
(defun %scan-down-to-atom (mark)
  (loop while (%scan-to-form mark t)
    do (unless (test-char (next-character mark) :lisp-syntax :open-paren)
         (return mark))
    do (mark-after mark)))

#+debug
(defun buffer-short-name ()
  (let* ((full-name (buffer-name (current-buffer)))
        (pos (position #\space full-name)))
    (if pos (subseq full-name 0 pos) full-name)))

;; Cache for actual color objects.
(defvar *lisp-code-colors-cache* nil)

;; (cached-lisp-code-colors)
(defun cached-lisp-code-colors ()
  ;; Assume nobody is going to destructively modify the list...
  (unless (eq *lisp-code-colors* (car *lisp-code-colors-cache*))
    (setq *lisp-code-colors-cache*
          (cons *lisp-code-colors*
                (loop
                  for (type . color-spec) in *lisp-code-colors*
                  do (when (and (consp color-spec) (null (cdr color-spec))) (setq color-spec (car color-spec)))
                  collect (cons type (hemlock-ext:lookup-color color-spec))))))
  (cdr *lisp-code-colors-cache*))

;; When get a cache miss, means we'll fill in parsing and line-origin caches for the whole buffer, so might
;; as well get a little extra coloring pre-computed in as well, for smoother scrolling...
(defparameter $coloring-cache-extra 1000)

(defstruct coloring-cache
  (tick nil)
  (start 0)
  (end 0)
  (data nil))

(defun make-sym-vec ()
  (make-array 0 :displaced-to "" :adjustable t))

(defun displace-to-region (sym-vec start-mark end-mark)
  (let* ((sym-line (mark-line start-mark))
         (line-str (line-string sym-line))
         (start-pos (mark-charpos start-mark))
         (end-pos (if (eq sym-line (mark-line end-mark))
                    (mark-charpos end-mark)
                    (progn
                      (setq line-str (region-to-string (region start-mark end-mark)))
                      (setq start-pos 0)
                      (length line-str)))))
    (ccl::%displace-array sym-vec nil (- end-pos start-pos) line-str start-pos T)))

#+debug
(defmethod print-object ((cache coloring-cache) stream)
  (print-unreadable-object (stream cache :identity nil :type t)
    (format stream "~s:~s @~s" (coloring-cache-start cache) (coloring-cache-end cache) (coloring-cache-tick cache))))

(defun hemlock:compute-syntax-coloring (start-pos length)
  (let* ((buffer (current-buffer))
         (end-pos (+ start-pos length))
         (tick (buffer-signature buffer))
         (cache (or (getf (buffer-plist buffer) 'coloring-cache)
                    (setf (getf (buffer-plist buffer) 'coloring-cache) (make-coloring-cache)))))
    (unless (and (eql (coloring-cache-tick cache) tick)
                 (<= (coloring-cache-start cache) start-pos)
                 (<= end-pos (coloring-cache-end cache))
                 ;; make sure colors haven't changed
                 (eq *lisp-code-colors* (car *lisp-code-colors-cache*)))
      (setq start-pos (max 0 (- start-pos $coloring-cache-extra)))
      (setq end-pos (+ end-pos $coloring-cache-extra))
      (let ((res (compute-syntax-coloring-in-region buffer start-pos end-pos)))
          (setf (coloring-cache-start cache) start-pos
                (coloring-cache-end cache) end-pos
                (coloring-cache-data cache) res
                (coloring-cache-tick cache) tick)))
    (coloring-cache-data cache)))


;; Map strings to symbols, to avoid consing strings for upcasing
(defvar *string-to-symbol-cache* (make-hash-table :test #'equalp))

(defun case-insensitive-string-to-symbol (string pkg)
  (when (null pkg) (setq pkg *package*))
  (let* ((pkg-alist (gethash string *string-to-symbol-cache*))
         (known (assoc pkg pkg-alist)))
    (if known
      (cdr known)
      (let* ((str (coerce string 'simple-string))
             (*package* pkg)
             (*read-eval* nil)
             (sym (ignore-errors (read-from-string str))))
        (setf (gethash str *string-to-symbol-cache*) (cons (cons pkg sym) pkg-alist))
        sym))))


;; Try to exclude use of symbol in data.
(defun mark-at-invocation-p (start-mark)
  (and (test-char (previous-character start-mark) :lisp-syntax :open-paren)
       (prog2
         (mark-before start-mark)
         (not (test-char (previous-character start-mark) :lisp-syntax :prefix))
         (mark-after start-mark))))

(defun compute-symbol-category (start-mark sym)
  (when (ccl::non-nil-symbol-p sym)
    (cond ((and (or (macro-function sym)
                    (ccl::special-form-p sym))
                (mark-at-invocation-p start-mark))
           :system-symbol)
          ((keywordp sym)
           :keyword)
          (t nil))))

(defvar *defining-symbols*
  '(defun defgeneric defmethod defmacro
     define-compiler-macro define-modify-macro define-symbol-macro
     define-setf-expander defsetf 
     defvar defparameter defconstant
     define-method-combination
     defclass defstruct deftype define-condition
     defpackage
     ccl:advise
     ccl:def-load-pointers 
     ccl:define-definition-type
     ccl:defloadvar
     ccl:defglobal ccl:defstaticvar ccl:define-declaration ccl:defstatic ccl:defcallback ccl:define-setf-method
     ccl:define-character-encoding
     ccl:defglobal
     hemlock-interface:defcommand
     hemlock-interface:define-file-option 
     hemlock-interface:define-file-type-hook
     hemlock-interface:define-keysym-code
     gui::def-cocoa-default
     objc:define-objc-class-method
     objc:define-objc-method
     objc:defmethod))

;; If true, the next atom following this sym will be automatically categorized as :definition, without going through compute-symbol-category.
(defun defining-symbol-p (start-mark sym)
  (and (mark-at-invocation-p start-mark)
       (or (member sym *defining-symbols*) ;; recognize these even if indented or embedded.
           (and (eql (mark-charpos start-mark) 1)  ;; but accept any toplevel "(def".
                (or (let ((str (string sym)))
                      (and (> (length str) 3) (string-equal "def" str :end2 3)))
                    ;; color top-level setq's, just for fun
                    (eq sym 'setq))))))


(defun compute-string/comment-coloring-in-region (region-start region-end)
  (let* ((lisp-code-colors (cached-lisp-code-colors))
         (start-line (mark-line region-start))
         (end-line (line-next (mark-line region-end)))
         (start-charpos (mark-charpos region-start)))
    (assert (not (eq start-line end-line)))
    (loop
      for line = start-line then (line-next line) until (eq line end-line)
      for info = (getf (line-plist line) 'lisp-info)
      when info
      nconc (loop with origin = (hi::line-origin line)
              for last-end = 0 then end-offset
              for (start-offset . end-offset) in (lisp-info-ranges-to-ignore info)
              for syntax = (if (eql start-offset 0)
                             (lisp-info-begins-quoted info)
                             (if (< last-end start-offset)
                               (character-attribute :lisp-syntax (line-character line (1- start-offset)))
                               :comment))
              do (when (member syntax '(:symbol-quote :string-quote))
                   (when (< 0 start-offset)
                     (decf start-offset))
                   (when (< end-offset (line-length line))
                     (incf end-offset)))
              unless (and (eq line start-line) (<= end-offset start-charpos))
              nconc (let* ((type (case syntax
                                   ((:char-quote :symbol-quote) nil)
                                   (:string-quote :string)
                                   (t (loop for i from start-offset as nsemi upfrom 0
                                        until (or (eql nsemi 3)
                                                  (eql i end-offset)
                                                  (not (test-char (line-character line i) :lisp-syntax :comment)))
                                        finally (return (case nsemi
                                                          (2 :double-comment)
                                                          (3 :triple-comment)
                                                          (t :comment)))))))
                           (color (and type (cdr (assq type lisp-code-colors)))))
                      (when color
                        (list (list* (+ origin start-offset) (- end-offset start-offset) color))))))))

(defun coloring-region (start-mark end-mark color)
  (when color
    (let* ((start (mark-absolute-position start-mark))
           (end (mark-absolute-position end-mark))
           (len (- end start)))
      (when (> len 0)
        (list* start len color)))))

(defun compute-symbol-coloring-in-region (region-start region-end)
  (let* ((sym-vec (make-sym-vec))
         (pkg nil)
         (lisp-colors (cached-lisp-code-colors))
         (defn-color (cdr (assq :definition lisp-colors))))
    (with-mark ((start-mark region-start)
                (end-mark region-start))
      (let ((pkgname (package-at-mark region-end end-mark)))
	(when pkgname
	  (when (mark< region-start end-mark)
	    ;; Argh, more than one package in region.  KLUDGE!!
	    (return-from compute-symbol-coloring-in-region
	      (nconc (compute-symbol-coloring-in-region region-start (mark-before end-mark))
		     (compute-symbol-coloring-in-region (mark-after end-mark) region-end))))
	  (setq pkg (find-package pkgname))))
      (loop
        while (and (%scan-to-symbol start-mark) (mark< start-mark region-end))
        for sym = (progn
                    (move-mark end-mark start-mark)
                    (unless (forward-form end-mark) (move-mark end-mark region-end))
                    (case-insensitive-string-to-symbol (displace-to-region sym-vec start-mark end-mark) pkg))
        for type = (compute-symbol-category start-mark sym)
        for reg = (when type
                    (let ((color (cdr (assq type lisp-colors))))
                      (when color
                        (coloring-region start-mark end-mark color))))
        when reg collect reg
        ;; if we're at start of a defining form, color the thing being defined.
        when (and defn-color
                  (defining-symbol-p start-mark sym)
                  (form-offset (move-mark start-mark end-mark) 1)
                  (%scan-down-to-atom end-mark)
                  (mark< end-mark region-end))
        collect (progn
                  (move-mark start-mark end-mark)
                  (unless (and (forward-form end-mark)
                               (mark<= end-mark region-end))
                    (move-mark end-mark region-end))
                  (unless (mark< start-mark end-mark)
                    (warn "definition got start ~s end ~s region-end ~s" start-mark end-mark
                          region-end)
                    (move-mark end-mark start-mark))
                  (coloring-region start-mark end-mark defn-color))
        do (rotatef start-mark end-mark)))))

(defun compute-syntax-coloring-in-region (buffer start-pos end-pos)
  (let* ((some-mark (buffer-point buffer)))
    (with-mark ((start-mark some-mark)
                (end-mark some-mark))
      (unless (move-to-absolute-position start-mark start-pos)
        (buffer-end start-mark))
      (unless (move-to-absolute-position end-mark end-pos)
        (buffer-end end-mark))
      (assert (mark<= start-mark end-mark))
      (when (mark< start-mark end-mark)
        (pre-command-parse-check start-mark)
        (sort (nconc (compute-string/comment-coloring-in-region start-mark end-mark)
                     (compute-symbol-coloring-in-region start-mark end-mark))
              #'< :key #'car)))))

