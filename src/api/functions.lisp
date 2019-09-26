(in-package #:cl-df)


(defun empty-column (header-class &rest row-parameters)
  (~>> (make-header header-class row-parameters)
       (cl-df.table:make-table 'cl-df.table:standard-table)))


(defun new-columns (table &rest columns)
  (~>> table
       cl-df.table:header
       class-of
       (cl-df:make-header _ columns)
       (cl-df.table:make-table (class-of table))
       (vstack table)))


(defun sample (table chance-to-pick &key (in-place *transform-in-place*))
  (check-type chance-to-pick (real 0 1))
  (transform table
             (lambda (&rest all)
               (declare (ignore all))
               (unless (< chance-to-pick (random 1.0d0))
                 (drop-row)))
             :in-place in-place))


(defun empty-table (&key (header (cl-df.header:header)))
  (cl-df.table:make-table 'cl-df.table:standard-table header))


(defun print-table (table
                    &key
                      (output *standard-output*)
                      (start 0)
                      (end 10))
  (check-type table cl-df.table:fundamental-table)
  (check-type output stream)
  (check-type start non-negative-integer)
  (check-type end non-negative-integer)
  (bind ((column-count (cl-df:column-count table))
         (end (min end (row-count table)))
         (number-of-rows (max 0 (- end start)))
         (strings (make-array `(,(1+ number-of-rows) ,column-count)))
         (header (cl-df.table:header table))
         (desired-sizes (make-array column-count
                                    :element-type 'fixnum
                                    :initial-element 0))
         ((:flet print-with-padding (row column))
          (let* ((string (aref strings row column))
                 (length (length string))
                 (desired-length (+ 2 (aref desired-sizes column))))
            (format output "~A" string)
            (unless (= (1+ column) column-count)
              (dotimes (i (- desired-length length))
                (format output "~a" #\space))))))
    (format output
            "~a columns × ~a rows. Printed rows from ~a below ~a:~%"
            column-count
            (row-count table)
            (min start end)
            end)
    (iterate
      (for j from 0 below column-count)
      (for string = (or (ignore-errors
                         (~> header
                             (cl-df.header:index-to-alias j)
                             symbol-name))
                        (format nil "~a" j)))
      (setf (aref strings 0 j) string)
      (setf (aref desired-sizes j) (length string)))
    (iterate
      (for i from start below end)
      (for row from 1)
      (iterate
        (for j from 0 below column-count)
        (for string = (princ-to-string (at table j i)))
        (setf (aref strings row j) string)
        (maxf (aref desired-sizes j) (length string))))
    (iterate
      (for j from 0 below column-count)
      (print-with-padding 0 j))
    (terpri output)
    (dotimes (i (+ (reduce #'+ desired-sizes)
                   (* (1- column-count)
                      2)))
      (princ #\= output))
    (terpri)
    (iterate
      (for i from 1 to number-of-rows)
      (iterate
        (for j from 0 below column-count)
        (print-with-padding i j))
      (terpri output))))
