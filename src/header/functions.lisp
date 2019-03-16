(in-package #:cl-data-frames.header)


(defun validate-active-row ()
  (when (null *row*)
    (error 'no-row)))


(defun validate-active-header ()
  (when (null *header*)
    (error 'no-header)))


(defun set-row (row)
  (validate-active-row)
  (setf (unbox *row*) row))


(defun row ()
  (validate-active-row)
  (unbox *row*))


(defun header ()
  (validate-active-header)
  *header*)


(defun decorate (range)
  (decorate-data (header) range))


(defun rr (index &optional (row (row)))
  (row-at (header) row index))


(defun (setf rr) (new-value index &optional (row (row)))
  (setf (row-at (header) row index) new-value))
