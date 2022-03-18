{:title "Couplings in Clojure testing tools"
 :layout :post
 :description "Exploring how Clojure test frameworks couple test evaluation with reporting"
 :tags  []
 :toc false}
<script src="../../js/clojure-mode.js" type="application/javascript"></script>


## back to the land of parens

Last time around I wrote up my experiences hacking JavaScript VMs in C++. It was a fun and wild time; modern VMs and C++ are, well, damn complex beasts!

Since then I've moved back to the Clojure world, where I've joined the [Nextjournal](https://nextjournal.com/) team.
We generally work on tools for thought, but also run some consultancy projects. For instance, the _Nextjournal_ reproducible notebook platform, as well as a local-first Clojure notebook tool called [Clerk](https://github.com/nextjournal/clerk).

So today I wanted to talk a bit about some fun I had with Clojure recently.
It has to do with test tooling; I'll start with some background experiences and then share a bit of code.

## background experience with test tools in Clojure

Back when I worked at Nubank, I spent a good amount of time trying to improve the test tooling we had for Clojure.

When I joined, Nubank used [_Midje_](https://github.com/marick/Midje/) widely, which is a testing DSL inspired by Ruby's [RSpec](https://rspec.info/).
Coming from Java, I found _Midje_ wonderfully expressive and capable but after some time realized that the DSL deviates from a few standards found in the Clojure ecosystem:

 * loading a namespace mixes code evaluation and test execution effects. This can get in the way of REPL-driven workflows and analysis tools.
 * assertions are described in a non-S-expression infix style `(fact (inc 1) => 2 (dec 1) => 0)`. This made it hard to use structural editing tools.
 * the library takes a strong "all or nothing" approach, where most Clojure libraries are small and composable.

Regardless, I started to hack on _Midje_ to tighten some holes I found myself falling into.
I eventually formed the opinion that, for the sake of maintainability and the points above, we should move to a collection of smaller and simpler testing tools.

_clojure.test_, being more or less pervasive in the eco-system, seemed like a good thing to try.
I found it a hard swallow when used in isolation: it was very bare-bones when compared to what _Midje_ was capable of.
But _clojure.test_ was small and extensible, and compatible with an approach of porting the best ideas from _Midje_ into a suite of smaller test-framework agnostic libraries.

We ended up with _clojure.test_ at the core, [_matcher-combinators_](https://github.com/nubank/matcher-combinators) for asserting over nested data-structures in a declarative way, and [_mockfn_](https://github.com/nubank/mockfn) for mocking.


## tests should produce data

In this time I often collaborated with [Sophia Velten](https://twitter.com/sophiavelten), who designed [_state-flow_](https://github.com/nubank/state-flow), the library Nubank uses for single-service integration tests.

One thing Sophia emphasized with _state-flow_ is that the result of running a test should be data.
It sounds like a simple and perhaps boring idea but has huge implications on the extensibility of a test framework.

For example, when _clojure.test_ tests are run, they emit detailed human-readable reports and return very coarse-grained summary as data `{:test 7, :pass 25, :fail 0, :error 0, :type :summary}`.
This creates additional burden to tool makers that might want to adapt this output.
For instance, [Arne Brasseur](https://twitter.com/plexus) details a bit in [this github comment](https://github.com/nubank/state-flow/issues/66#issuecomment-576801166) how they handled this in the [_Kaocha_ test runner](https://github.com/lambdaisland/kaocha).

This is workable with _clojure.test_, given that it uses user-override-able multimethods for its reporting.

I guess my issue with this design is tool builders are still required to do a good bit of work. I imagine this work has unfortunately been repeated many times by different people in different dev tool code.

To concretize my point, _clojure.test_ currently works like this
<div id="decouple"></div>

<script>nextjournal.clojure_mode.demo.render("decouple", `(require '[clojure.test :refer [deftest is testing]])

(deftest example-test
  (testing "this will fail"
    (is (= 1 2))))

;; running is coupled with reporting
(clojure.test/run-test-var #'example-test)
;; =>
;; FAIL in (example-test) (NO_SOURCE_FILE:74)
;; this will fail
;; expected: (= 1 2)
;;   actual: (not (= 1 2))
{:test 1, :pass 0, :fail 1, :error 0, :type :summary}`)</script>

<br>
And if test evaluation and reporting were decoupled, it could look like the following, which would give nice hooks for those working on dev tooling

<br>
<br>

<div id="as-data"></div>

<script>nextjournal.clojure_mode.demo.render("as-data", `(defn evaluate-test-var [test-var] 
  ...)

;; such that
(evaluate-test-var #'example-test)
;; =>
{#'scratch/example-test
 [{:file "NO_SOURCE_FILE"
   :line 74
   :type :fail
   :expected (= 1 2)
   :actual (not (= 1 2))
   :message nil,
   :context-str ("this will fail")}]}

(defn report! [report-data] 
  ...)

;; such that clojure.test/run-test-var could be defined as:
(def clojure.test/run-test-var (comp report! evaluate-test-var))`)</script>

<br>

## Clerk + testing

Okay, but why am I rambling about this at all?

Well I wanted to get a hold of more fine-grained test result data to start playing around with building test-related tools for Clerk, a local-first Clojure notebook tool.

And what is _Clerk_ exactly?

It is a computational notebook tool for Clojure, which gives you the interactivity and visualization gains of a notebook while still embracing your existing dev flow. Notebooks developed locally but can be published online statically by bundling the data generated from the Clojure code and publishing it with the front-end Clojurescript viewer code.

My colleagues at Nextjournal have been making some [really](https://nextjournal.github.io/clerk-demo/) [cool](https://twitter.com/mkvlr/status/1503767871620538375) [stuff](https://twitter.com/mkvlr/status/1499470357262127106) with it! They've taken to chatting me up about how _Clerk_ could be applied to testing dev experience.

Like imagine being able to do your dev in Emacs or Neovim, but have a test runner that printed _matcher-combinator_ mismatch test failures, where irrelevant parts of the data-structure were auto-folded away.

Or you could add tests to your notebooks, plus a button to run them, and see highlighting for assertion forms that pass or fail.

So this is why I sat down to see how I could get _clojure.test_ to provide test result data to then send over to custom _Clerk_ viewers.


## separating test execution from test reporting

As I dove into trying to get _clojure.test_ data I realized there were no APIs for providing fine-grained report results. Like getting, as data, exactly which assertion forms failed and what `deftest` variables they are associated with doesn't seem possible.

I found myself needing to solve the issue of decoupling test execution from test reporting, the thing that Sophia was so spot on about in _state-flow_'s design years ago.

Hacking a bit, I found a solution that seemed pretty cute:

<div id="editor"></div>

<script>nextjournal.clojure_mode.demo.render("editor", `(require '[clojure.test :as t])

;; grab the old clojure.test reporting multimethod implementations
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

;; redef reporting to store result map & dispatch to old definition
(defmethod t/report :pass [m]
  (register-test-result! m)
  ((get test-report-methods :pass) m))

(defmethod t/report :fail [m]
  (register-test-result! m)
  ((get test-report-methods :fail) m))

(defmethod t/report :error [m]
  (register-test-result! m)
  ((get test-report-methods :error) m))

;; running is decoupled into eval and report
(defn evaluate-test-var [test-var]
  (binding [*test-results* (ref {})
            t/*test-out* (new java.io.StringWriter)]
    (t/test-vars [test-var])
    @*test-results*))

(defn report! [report-data]
  (run! (fn [[test-var results]]
          (run! #(binding [t/*testing-contexts* (:context-str %)
                           t/*testing-vars* [test-var]]
                   ((get test-report-methods (:type %)) %))
                results))
        report-data))

;; now let's use it
(def my-run-test-var (comp report! evaluate-test-var))

(my-run-test-var #'example-test)
;; which is equivalent to clojure.test/run-test-var:
(t/run-test-var #'example-test)`);
</script>

<br>

What is going on here?
Well, _clojure.test_ reporting is implemented using Clojure's multimethods, which allow you to dispatch to different function bodies depending on some dispatch criteria defined by `defmulti`. For instance, `clojure.test/report` looks like `(defmulti report :type)`, so the `:type` data of the arg passed into `report` specifies the behavior.

Multimethods are a nice way to bake extensibility into your libraries because one can always define a new multimethod dispatch/body.

For example, in the _matcher-combinators_ integration with _clojure.test_, we were able to display custom _matcher-combinators_ mismatch results by extending `clojure.test/report` in the _matcher-combinators_ library itself, allowing operation over `:mismatch`, a new test result type we created (it [looked like this](https://github.com/nubank/matcher-combinators/pull/49/files#diff-c7340dd400d00da94964e2a1113886bd367b364028e0bdebdd9dc09e7f390a81L50) but was eventually migrated)

What I'm doing now with the `report` multimethods above is stashing the old versions with [`methods`](https://clojuredocs.org/clojure.core/methods) (which I was delighted to discover this existed today), and redefining them to new behavior that eventually dispatches back to the stashed original. Essentially a hacky "call super"; using it ensures that the old _clojure.test_ API continues to work fine. The new versions also accumulate some report data using same weird `binding`, `dosync`, `commute` stuff; a pattern I lift from the _clojure.test_ code itself.

With the `report` definitions hijacked, we can implement `evaluate-test-var` to mute any results printed by _clojure.test_ and also return the accumulated report data.

The new `report!` functionality then iterates through the report data produced by `evaluate-test-var` and calls the original _clojure.test_ report functions (those that we stashed using `methods`) on the data.

You can try it out in your own REPL; you should see something like this:

<div id="results"></div>

<script>nextjournal.clojure_mode.demo.render("results", `(evaluate-test-var #'example-test)
;; =>
{#'scratch/example-test
 [{:file "NO_SOURCE_FILE",
   :line 74,
   :type :fail,
   :expected (= 1 2),
   :actual (not (= 1 2)),
   :message nil,
   :context-str ("this will fail")}]}

((comp report! evaluate-test-var) #'example-test)
;; =>
;; FAIL in (example-test) (NO_SOURCE_FILE:74)
;; this will fail
;; expected: (= 1 2)
;;   actual: (not (= 1 2))`);
</script>

<br>

Cute, no? And fun how Clojure provides all the tools needed to do such adaptations to _clojure.test_.
And it isn't the only way to achieve this. Another approach could be to use `with-redefs` over `clojure.test/do-report`, which is the one place that `clojure.test/report` is called.

At Nubank we'd sometime toss around the idea of writing our own test framework that explicitly decouples execution and reporting. Yet after working out this snippet of code I'm wondering how far we can get purely through adaption.
