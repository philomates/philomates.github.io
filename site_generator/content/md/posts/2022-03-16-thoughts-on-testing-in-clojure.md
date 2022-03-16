{:title "Thoughts on testing in Clojure"
 :layout :post
 :description ""
 :tags  []
 :toc false}



<div id="editor"></div>

<script src="../../js/clojure-mode.js" type="application/javascript"></script>

<script>nextjournal.clojure_mode.demo.render("editor", `(require '[clojure.test :as t])

(defonce test-report-methods (methods t/report))

(def ^:dynamic *test-results* nil)

(defn- register-test-result! [m]
  (when *test-results*
    (when-let [test-var (last t/*testing-vars*)]
      (dosync
        (commute *test-results*
                 update
                 test-var
                 (fnil conj [])
                 (assoc m :context-str t/*testing-contexts*))))))

(defmethod t/report :pass [m]
  (register-test-result! m)
  ((get test-report-methods :pass) m))

(defmethod t/report :fail [m]
  (register-test-result! m)
  ((get test-report-methods :fail) m))

(defmethod t/report :error [m]
  (register-test-result! m)
  ((get test-report-methods :error) m))

(defn tests->data [ns]
  (binding [*test-results* (ref {})
            t/*test-out* (new java.io.StringWriter)]
    (t/test-ns ns)
    @*test-results*))

(defn data->report [report-data]
  (run! (fn [[test-var results]]
          (run! #(binding [t/*testing-contexts* (:context-str %)
                           t/*testing-vars* [test-var]]
                   ((get test-report-methods (:type %)) %))
                results))
        report-data))

(-> *ns*
    ;; run get test results as data w/o printing
    tests->data
    ;; print standard clojure.test results
    data->report)

(comment
  ;; the above is equivalent to:
  (t/test-ns *ns*))`);
