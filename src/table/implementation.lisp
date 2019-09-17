(in-package #:cl-df.table)


(defun make-iterator (columns &key (transformation #'identity))
  (cl-df.column:make-iterator columns :transformation transformation))


(defmethod at ((frame standard-table) (column symbol) (row integer))
  (~> frame header
      (cl-df.header:alias-to-index column)
      (at frame _ row)))


(defmethod at ((frame standard-table) (column integer) (row integer))
  (check-type column non-negative-integer)
  (check-type row non-negative-integer)
  (let* ((columns (read-columns frame))
         (length (array-dimension columns 0)))
    (unless (< column length)
      (error 'cl-df.header:no-column
             :bounds (iota length)
             :format-arguments (list column)
             :value column))
    (~> (aref columns column)
        (cl-df.column:column-at row))))


(defmethod (setf at) (new-value (frame standard-table)
                      (column symbol) (row integer))
  (setf (at frame (cl-df.header:alias-to-index (header frame)
                                               column)
            row)
        new-value))


(defmethod (setf at) (new-value (frame standard-table)
                      (column integer) (row integer))
  (check-type column non-negative-integer)
  (check-type row non-negative-integer)
  (let* ((columns (read-columns frame))
         (length (array-dimension columns 0)))
    (unless (< column length)
      (error 'cl-df.header:no-column
             :bounds (iota length)
             :format-arguments (list column)
             :value column))
    (setf (cl-df.column:column-at (aref columns column) row)
          new-value)))


(defmethod column-count ((frame standard-table))
  (~> frame header cl-df.header:column-count))


(defmethod row-count ((frame standard-table))
  (~> frame read-columns
      (extremum #'> :key #'cl-df.column:column-size)
      cl-df.column:column-size))


(defmethod column-name ((frame standard-table) (column integer))
  (~> frame header
      (cl-df.header:index-to-alias column)))


(defmethod column-type ((frame standard-table) column)
  (~> frame header (cl-df.header:column-type column)))


(defmethod vstack ((frame standard-table) more-frames)
  (let* ((new-columns
           (map 'vector
                (lambda (column &aux (new (cl-ds:replica column t)))
                  (~>> new
                       cl-ds.common.abstract:read-ownership-tag
                       (cl-ds.dicts.srrb:transactional-insert-tail! new))
                  new)
                (read-columns frame)))
         (iterator (make-iterator new-columns))
         (new-frame (cl-ds.utils:quasi-clone*
                        frame :columns new-columns))
         (column-count (column-count new-frame))
         (row-count (row-count new-frame)))
    (with-table (new-frame)
      (cl-df.column:move-iterator iterator row-count)
      (cl-ds:across
       more-frames
       (lambda (frame)
         (unless (eql column-count (column-count frame))
           (error 'cl-df.header:headers-incompatible
                  :header (header frame)
                  :control-string "Inconsistent number of columns in the frames."))
         (cl-ds:traverse
          frame
          (cl-df.header:body ()
            (iterate
              (for i from 0 below column-count)
              (setf (cl-df.column:iterator-at iterator i)
                    (cl-df.header:rr i)))
            (cl-df.column:move-iterator iterator 1))))))
    (cl-df.column:finish-iterator iterator)
    new-frame))


(defmethod hstack ((frame standard-table) more-frames)
  (cl-ds:across more-frames
                (lambda (x) (check-type x standard-table)))
  (let* ((more-frames (~>> (cl-ds.alg:accumulate more-frames
                                                 (flip #'cons)
                                                 :initial-value nil)
                           nreverse
                           (cons frame)))
         (header (apply #'cl-df.header:concatenate-headers
                        (mapcar #'header more-frames)))
         (column-count (cl-df.header:column-count header))
         (new-columns (make-array column-count))
         (index 0))
    (declare (type fixnum index column-count)
             (type simple-vector new-columns)
             (type list more-frames))
    (iterate
      (for frame in more-frames)
      (for columns = (read-columns frame))
      (iterate
        (for column in-vector columns)
        (setf (aref new-columns index) (cl-ds:replica column t))
        (the fixnum (incf index))))
    (make 'standard-table
          :header header
          :columns new-columns)))


(defmethod vselect ((frame standard-table) selector)
  (let* ((header (header frame))
         (columns (read-columns frame))
         (column-indexes (~>> (curry #'cl-df.header:alias-to-index header)
                              (cl-ds.utils:if-else #'integerp #'identity)
                              (cl-ds.alg:on-each selector)
                              cl-ds.alg:to-vector))
         (new-header (cl-df.header:select-columns header column-indexes))
         (new-columns (map 'vector (compose (rcurry #'cl-ds:replica t)
                                            (curry #'aref columns))
                           column-indexes)))
    (declare (type simple-vector columns new-columns))
    (cl-ds.utils:quasi-clone* frame
      :header new-header
      :columns new-columns)))


(defmethod hselect ((frame standard-table) (selector selection))
  (bind ((columns (read-columns frame))
         (column-count (length columns))
         (starts (read-starts selector))
         (ends (read-ends selector))
         (new-columns (map 'vector
                           (lambda (x)
                             (cl-df.column:make-sparse-material-column
                              :element-type (cl-df.column:column-type x)))
                           columns)))
    (declare (type simple-vector new-columns columns)
             (type fixnum column-count))
    (when (emptyp new-columns)
      (return-from hselect (cl-ds.utils:quasi-clone* frame
                            :columns new-columns)))
    (iterate
      (with iterator = (make-iterator new-columns))
      (for start in-vector starts)
      (for end in-vector ends)
      (for source-iterator = (make-iterator columns))
      (cl-df.column:move-iterator source-iterator start)
      (iterate
        (for i
             from start
             below end)
        (iterate
          (declare (type fixnum column-index))
          (for column-index from 0 below column-count)
          (for column = (aref new-columns column-index))
          (setf (cl-df.column:iterator-at iterator column-index)
                (cl-df.column:iterator-at source-iterator column-index)))
        (cl-df.column:move-iterator iterator 1)
        (cl-df.column:move-iterator source-iterator 1))
      (finally (cl-df.column:finish-iterator iterator)))
    (cl-ds.utils:quasi-clone* frame
      :columns new-columns)))


(defmethod hselect ((frame standard-table) selector)
  (bind ((columns (read-columns frame))
         (column-count (length columns))
         (new-columns (map 'vector
                           (lambda (x)
                             (cl-df.column:make-sparse-material-column
                              :element-type (cl-df.column:column-type x)))
                           columns)))
    (declare (type simple-vector new-columns)
             (type fixnum column-count))
    (when (emptyp new-columns)
      (return-from hselect (cl-ds.utils:quasi-clone* frame
                            :columns new-columns)))
    (let ((iterator (make-iterator new-columns)))
      (cl-ds:traverse
       selector
       (lambda (row)
         (iterate
           (declare (type fixnum column-index))
           (for column-index from 0 below column-count)
           (for column = (aref columns column-index))
           (setf (cl-df.column:iterator-at iterator column-index)
                 (cl-df.column:column-at column row)))
         (cl-df.column:move-iterator iterator 1)))
      (cl-df.column:finish-iterator iterator)
      (cl-ds.utils:quasi-clone* frame
        :columns new-columns))))


(defun ensure-replicas (columns new-columns)
  (iterate
    (for i from 0 below (length new-columns))
    (for new-column = (aref new-columns i))
    (for column = (aref columns i))
    (if (eq column new-column)
        (setf (aref new-columns i)
              (cl-ds:replica new-column t))
        (progn
          (assert
           (not (eq (cl-ds.common.abstract:read-ownership-tag column)
                    (cl-ds.common.abstract:read-ownership-tag new-column))))
          (assert
           (not (eq (cl-ds.dicts.srrb:access-tree column)
                    (cl-ds.dicts.srrb:access-tree new-column)))))))
  new-columns)


(defmethod vmask ((frame standard-table) mask
                  &key (in-place *transform-in-place*))
  (bind ((columns (read-columns frame))
         (column-count (length columns))
         (old-size (row-count frame))
         (new-size 0))
    (declare (type fixnum new-size old-size column-count))
    (when (zerop column-count)
      (return-from vmask frame))
    (cl-df.header:with-header ((header frame))
      (let* ((transform (rcurry #'cl-ds:replica (not in-place)))
             (iterator (make-iterator columns :transformation transform))
             (new-columns (cl-df.column:columns iterator)))
        (assert (not (eq new-columns columns)))
        (cl-df.header:set-row (make 'table-row :iterator iterator))
        (block out
          (cl-ds:traverse
           mask
           (lambda (accepted)
             (unless (< new-size old-size)
               (return-from out))
             (when (not accepted)
               (iterate
                 (for column in-vector new-columns)
                 (for column-index from 0 below column-count)
                 (setf (cl-df.column:iterator-at iterator column-index)
                       :null)))
             (cl-df.column:move-iterator iterator 1)
             (incf new-size))))
        (cl-df.column:finish-iterator iterator)
        (iterate
          (for column in-vector new-columns)
          (cl-df.column:truncate-to-length column new-size))
        (if in-place
            (progn
              (write-columns new-columns frame)
              frame)
            (cl-ds.utils:quasi-clone* frame
              :columns (ensure-replicas columns new-columns)))))))


(defun remove-nulls-from-columns (columns)
  (bind ((column-count (length columns)))
    (when (zerop column-count)
      (return-from remove-nulls-from-columns columns))
    (let* ((iterator (make-iterator columns))
           (new-columns (cl-df.column:columns iterator)))
      (assert (not (eq new-columns columns)))
      (cl-df.column:remove-nulls iterator)
      new-columns)))


(defmethod transform ((frame standard-table) function
                      &key (in-place *transform-in-place*))
  (ensure-functionf function)
  (bind ((columns (read-columns frame))
         (column-count (length columns))
         (old-size (row-count frame)))
    (when (zerop column-count)
      (return-from transform frame))
    (with-table (frame)
      (let* ((transform (rcurry #'cl-ds:replica (not in-place)))
             (header (header frame))
             (column-count (column-count frame))
             (iterator (make-iterator columns :transformation transform))
             (row (make 'setfable-table-row :iterator iterator))
             (new-columns (cl-df.column:columns iterator))
             (marker-column (cl-df.column:make-sparse-material-column
                             :element-type 'bit))
             (dropped nil)
             (marker-iterator (make-iterator (vector marker-column))))
        (assert (not (eq new-columns columns)))
        (cl-df.header:set-row row)
        (iterate
          (for i from 0 below old-size)
          (let ((*transform-control*
                  (lambda (operation)
                    (eswitch (operation :test 'eq)
                      (:finish (leave))
                      (:drop
                       (iterate
                         (for i from 0 below column-count)
                         (setf (cl-df.header:row-at header row i) :null))
                       (setf (cl-df.column:iterator-at marker-iterator 0) 0
                             dropped t)
                       (next-iteration))
                      (:nullify
                       (iterate
                         (for i from 0 below column-count)
                         (setf (cl-df.header:row-at header row i) :null)))))))
            (funcall function))
          (cl-df.column:move-iterator marker-iterator 1)
          (cl-df.column:move-iterator iterator 1))
        (cl-df.column:finish-iterator iterator)
        (when dropped
          (cl-df.column:finish-iterator marker-iterator)
          (setf marker-iterator (make-iterator (vector marker-column)))
          (iterate
            (for i from 0 below old-size)
            (for value = (cl-df.column:iterator-at marker-iterator 0))
            (if (eq :null value)
                (setf (cl-df.column:iterator-at marker-iterator 0) 1)
                (setf (cl-df.column:iterator-at marker-iterator 0) :null))
            (cl-df.column:move-iterator marker-iterator 1))
          (cl-df.column:finish-iterator marker-iterator)
          (let ((cleaned-columns (adjust-array new-columns
                                               (1+ column-count))))
            (setf (last-elt cleaned-columns) marker-column
                  new-columns (~> (remove-nulls-from-columns cleaned-columns)
                                  (adjust-array column-count)))))
        (if in-place
            (progn
              (write-columns new-columns frame)
              frame)
            (cl-ds.utils:quasi-clone* frame
              :columns (ensure-replicas columns new-columns)))))))


(defmethod remove-nulls ((frame standard-table)
                         &key (in-place *transform-in-place*))
  (let* ((columns (read-columns frame))
         (clones (map 'vector
                      (lambda (x)
                        (cl-ds:replica x (not in-place)))
                      columns))
         (new-columns (remove-nulls-from-columns clones)))
    (when (eq clones new-columns)
      (return-from remove-nulls frame))
    (if in-place
        (progn
          (write-columns new-columns frame)
          frame)
        (cl-ds.utils:quasi-clone* frame
          :columns (ensure-replicas columns new-columns)))))


(defmethod cl-df.header:row-at ((header cl-df.header:standard-header)
                                (row table-row)
                                (position symbol))
  (cl-df.header:row-at header row (cl-df.header:alias-to-index header
                                                               position)))


(defmethod (setf cl-df.header:row-at) (new-value
                                       (header cl-df.header:standard-header)
                                       (row setfable-table-row)
                                       (position symbol))
  (setf (cl-df.header:row-at header row
                             (cl-df.header:alias-to-index header
                                                          position))
        new-value))


(defmethod cl-df.header:row-at ((header cl-df.header:standard-header)
                                (row table-row)
                                position)
  (~> row read-iterator (cl-df.column:iterator-at position)))


(defmethod (setf cl-df.header:row-at) (new-value
                                       (header cl-df.header:standard-header)
                                       (row setfable-table-row)
                                       position)
  (setf (~> row read-iterator (cl-df.column:iterator-at position))
        new-value))


(defmethod cl-ds:whole-range ((container standard-table))
  (let* ((columns (read-columns container))
         (columns-count (length columns))
         (row-count (row-count container))
         (header (header container)))
    (if (zerop columns-count)
        (make 'cl-ds:empty-range)
        (make 'standard-table-range
              :table-row (make 'table-row :iterator (make-iterator columns))
              :row-count row-count
              :header header))))


(defmethod cl-ds:clone ((range standard-table-range))
  (cl-ds.utils:quasi-clone* range
    :table-row (make 'table-row
                     :iterator (cl-ds:clone (read-iterator range)))))


(defmethod read-iterator ((range standard-table-range))
  (~> range read-table-row read-iterator))


(defmethod cl-ds:peek-front ((range standard-table-range))
  (bind ((row-count (read-row-count range))
         (iterator (read-iterator range))
         (row (cl-df.column:index iterator))
         (header (read-header range))
         (column-count (cl-df.header:column-count header)))
    (if (< row row-count)
        (iterate
          (with result = (make-array column-count))
          (for i from 0 below column-count)
          (setf (aref result i) (cl-df.column:iterator-at iterator i))
          (finally (return (values result t))))
        (values nil nil))))


(defmethod cl-ds:become-transactional ((container standard-table))
  (cl-ds:replica container))


(defmethod cl-ds:replica ((container standard-table) &optional isolate)
  (cl-ds.utils:quasi-clone* container
    :columns (~>> container read-columns
                  (map 'vector (rcurry #'cl-ds:replica isolate)))))


(defmethod cl-ds:drop-front ((range standard-table-range)
                             count)
  (check-type count non-negative-fixnum)
  (let* ((iterator (read-iterator range))
         (count (clamp count 0 (- (read-row-count range)
                                  (cl-df.column:index iterator)))))
    (when (zerop count)
      (return-from cl-ds:drop-front (values range count)))
    (cl-df.column:move-iterator iterator count)
    (values range count)))


(defmethod cl-ds:consume-front ((range standard-table-range))
  (bind ((row-count (read-row-count range))
         (iterator (read-iterator range))
         (row (cl-df.column:index iterator))
         (header (read-header range))
         (column-count (cl-df.header:column-count header)))
    (if (< row row-count)
        (iterate
          (with result = (make-array column-count))
          (for i from 0 below column-count)
          (setf (aref result i) (cl-df.column:iterator-at iterator i))
          (finally
           (cl-df.column:move-iterator iterator 1)
           (return (values result t))))
        (values nil nil))))


(defmethod cl-ds:traverse ((range standard-table-range)
                           function)
  (ensure-functionf function)
  (bind ((iterator (read-iterator range))
         (row (read-table-row range))
         (row-count (read-row-count range)))
    (cl-df.header:set-row row)
    (iterate
      (while (< (cl-df.column:index iterator) row-count))
      (funcall function row)
      (cl-df.column:move-iterator iterator 1))
    (values nil nil)))


(defmethod cl-ds:reset! ((range standard-table-range))
  (cl-ds:reset! (read-iterator range))
  range)


(defmethod cl-ds:traverse ((table standard-table) function)
  (with-table (table)
    (cl-ds:traverse (cl-ds:whole-range table)
                    function))
  table)


(defmethod cl-ds:across ((table standard-table) function)
  (cl-ds:traverse table function))


(defmethod cl-ds.alg.meta:apply-range-function ((range standard-table)
                                                function
                                                &rest all)
  (with-table (range)
    (apply #'cl-ds.alg.meta:apply-range-function
           (cl-ds:whole-range range)
           function all)))


(defmethod cl-ds:traverse ((selection selection)
                           function)
  (ensure-functionf function)
  (iterate
    (for i from (read-start selection) below (read-end selection))
    (funcall function i))
  selection)


(defmethod cl-ds:across ((selection selection)
                         function)
  (cl-ds:traverse selection function))


(defmethod make-table ((class (eql 'standard-table))
                       (header cl-df.header:fundamental-header))
  (make 'standard-table
        :header header
        :columns (iterate
                   (with columns = (~> header
                                       cl-df.header:column-count
                                       make-array))
                   (for i from 0 below (cl-df.header:column-count header))
                   (setf (aref columns i)
                         (cl-df.column:make-sparse-material-column
                          :element-type (cl-df.header:column-type header i)))
                   (finally (return columns)))))
