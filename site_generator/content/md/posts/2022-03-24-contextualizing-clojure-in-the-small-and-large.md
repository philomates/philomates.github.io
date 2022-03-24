{:title "Contextualizing Clojure in the small and the large"
 :layout :post
 :description "What I've learned about a large Clojure organization by working at a small one"
 :tags  []
 :toc false}
<script src="../../js/clojure-mode.js" type="application/javascript"></script>

```plain
One of the best ways to grow at a job is to leave it
```


I always saw leaving one job for another as opportunity for new experiences.
Recently though, I've been reflecting on how changing jobs is equally important for challenging and integrating prior experiences.

In my tech career, job changes usually came with a change to the domain and tech stack as well.
I've jumped from building offline-first Android apps in [international health](https://dimagi.com/), to working on Clojure-backed microservices at a [bank](https://building.nubank.com.br/), to working on JS VMs with an [open-source co-op](https://www.igalia.com/).
There was fun to be had with each fresh tech-stack, along with the variety of new constraints that come with each new domain.

But only recently have I had the opportunity to work in a context similar to that of a previous one.

At my current workplace we use Clojure and Datomic, both of which were go-to tools during my ~4 years of building microservices at Nubank.
Perhaps obvious, but surprising to me, this overlap has proven to be a great opportunity to integrate what I was exposed to during my time at Nubank.
In fact, I only now feel able to properly understand and reflect upon key decisions and patterns I encountered there.

## the Nubank times

When I joined Nubank in early 2017, they had a somewhat solidified tech stack that was serving ~1 million clients.
We were around 75 engineers and our bread-and-butter tech tools, Clojure, Datomic, Kafka, and S3, were all already in place.
Additionally, the microservice architecture, and how we mocked it out for unit and integration testing, had been shown viable.

Interestingly, almost nobody on the team had used these niche tech tools before joining.
So, Clojure for me, as well as most others joining, was defined by what was in place when we joined:

 * The [_Midje_](https://github.com/marick/Midje) test-runner was heavily utilized. It can watch namespaces, reload changes, and re-run the relevant tests. With this workflow it was easy to ignore the REPL and REPL-driven development remained a mystery to me for a good 2 years, until I paired with a colleague more familiar with it.
 * We used an internal wrapper library around Datomic that mediated reads and writes. Users operated on map data-structures described using [plumatic schema](https://github.com/plumatic/schema) as a stand-in for Datomic entities. This meant that, aside from writing queries and defining entity models, Datomic for me was more or less a mystery.
 * We always wrapped stateful 3rd-party libraries with (Clojure) protocols defining our own hand-rolled APIs. This allowed us to constrain methods of interacting with external libraries, as well as providing mocked versions of these protocol APIs for use in tests.
 * Microservices across the organization adhered more or less to a uniform architecture. While this contained a lot of ceremonial boilerplate, it was consistent enough that, after a few weeks, I was able to pattern-match/copy-paste my way through most simple feature implementations.

As Nubank grew we started hiring and working with people who had had professional Clojure experience before joining Nubank.
Most of them expressed some level of discomfort with our established manners of interacting with and writing Clojure code, and I never really understood where this came from.

## attempting to program in the small using patterns from programming in the large

I figured that when I joined [Nextjournal](nextjournal.com/) I'd be able to bring a lot of nice Nubank experiences and ideas to the table.
I've been surprised to see how, even though both places use Clojure and Datomic, the patterns I learned at Nubank make little sense on a small engineering team.

Through the experience of working at Nextjournal I've started to better contextualize and understand Nubank's approach to Clojure and understand how it deviates from what many Clojurists are used to.

### the REPL

It is kind of crazy that for the first year or two using Clojure I basically didn't know about the REPL.
This lead to some wild workflows, like if I wanted to debug a library issue arising in a microservice, I checkout and modify the source, install it locally via `lein install`, and restart my Midje test runner.
Test coverage was good and the Midje test runner did code reloading, so the test suite felt like a fine entry point to interacting with our systems.

Even with me oblivious, I'm sure other Nubank engineers were into the REPL-driven flow. That said, at Nextjournal I'm noticing that the REPL-driven workflow not only informs the development process but also the structure of code.

#### reloadable code

Writing code in a manner that works well with reloading is something we did at Nubank.
For instance, sometimes at Nubank we'd reference functions via `(var some-function)` instead of the standard `some-function` to ensure that changes to `some-function` were propagated even when `some-function` references were bound to intermediates.

Yet, at Nextjournal, it seems to hold much more influence.
Clojure protocols, which we used extensively for mocking at Nubank, are avoided [given their issues with code reloading](https://nelsonmorris.net/2015/05/18/reloaded-protocol-and-no-implementation-of-method.html).
This was also one of the main factors when choosing a software component management library; where [integrant](https://github.com/weavejester/integrant) was preferred over [component](https://github.com/stuartsierra/component) due to it being designed around protocols.

#### interactivity

To me it has been interesting to see how REPL-driven workflows might shape the general structure of code.

To take an extreme example, compare

<div id="exi"></div>

<script>nextjournal.clojure_mode.demo.render("exi", `(defn lookup-users-i []
  (query (get-db-conn)
         '[:find [?user ...] :in $ :where [?user :user/name _]]))`)</script>

to

<div id="exii"></div>

<script>nextjournal.clojure_mode.demo.render("exii", `(defn lookup-users-ii [db-conn]
  (query db-conn
         '[:find [?user ...] :in $ :where [?user :user/name _]]))`)</script>

The first version is easier to invoke via the REPL because you offload any db connection setup logic to the `get-db-conn` function.
You don't need to worry about building a connection and passing it in.
On the flip-side, at any `lookup-user-i` call-sites you don't have arguments going in, which give readers of the code less context to the behavior when compared to passing a db connection.

I don't know what the correct balance is here but it has been interesting to include REPL interactiveness as a factor to weighing code designs.

#### approach to tests

REPL-driven flows have, to me, sometimes felt at odds with maintaining good test coverage.
While Nubank's culture was pretty test-centric, folks I'd chat up from the larger Clojure community sometimes seemed to view tests as secondary.

I can understand how a REPL-centric dev flow can take the place of a more test-driven one, since the REPL is a great tool for a single engineer to validate behavior.
Yet given this viability I wonder how often it inhibits one from switching contexts to write tests, which are a critical way of communicating on a team.

Nextjournal is still missing a lot of test harness code, so I've been having some fun trying to see if the tools that worked at Nubank can apply to a smaller team.
For instance, I'm trialing [_state-flow_](https://github.com/nubank/state-flow/) in one of our projects at Nextjournal.
_state-flow_ is a DSL that encourages a relatively constrained way of writing single-service integration tests, which works great when you have hundreds of engineers writing tests.
At the same time, I'm not yet sure if the overhead of this DSL makes sense on a small team.

One place where I think tests can work well with REPL-driven dev is in the context of seed data.
A colleague of mine that practices REPL-driven dev recently wanted to interact with some logic I'd written and was asking how he could seed the system with useful example data.
Someone practicing REPL-driven dev would probably have a REPL session namespace lying around that calls directly into functions in the service to seed the system.
But my feature work takes a much more test-driven approach so I had no REPL sessions to share, only my tests.
Luckily, through the process of running a test, the system effectively gets seeded with data.
Since our integration tests only interact with the service at its HTTP endpoints, the seed data is coherent, complete, and robust to changes to both internal data models and code layout. This to me is an added benefit over a REPL session namespace.

I wrote a little snippet that runs a test defined with _state-flow_'s `defflow` (analogous to _clojure.test_'s `deftest`) and returns the resulting service system for you to interact with in the REPL:

<div id="stateflow"></div>

<script>nextjournal.clojure_mode.demo.render("stateflow", `(require '[state-flow.api :refer [defflow match? flow]])
(require '[integrant.core])

(defn create-user [username]
  (flow "make some http reqs to service to build user"
    ...))

(defflow my-flow
  {:init (fn [] {:system (integrant.core/init ...)})}
  (create-user "Estragon")
  (match? "Estragon" ..lookup-user..))

(defn run-flow->result-system
  "run a defflow, returning the resulting system"
  [defflow-var]
  (let [var-meta (meta defflow-var)
        init-fn  (get-in var-meta [:state-flow :parameters :init])
        run-fn   (get-in var-meta [:state-flow :parameters :runner]
                         state-flow.api/run)
        flow     (get-in var-meta [:state-flow :flow])
        system   (if init-fn (init-fn) {})]
    (-> (run-fn flow system)
        second
        :system)))

(def system (run-flow->result-system #'my-flow))

;; now you can run code that needs stateful parts of the service:
(lookup-users-ii (:db-conn system))

;; be sure to call halt! on the system before starting a new one
;; otherwise some singleton stuff might not work:
#_(integrant.core/halt! system)`)</script>

I've been using this snippet lately on a consultancy project while developing some operational dashboards written in [Clerk](https://github.com/nextjournal/clerk).
It has provided a way to quickly get a service instance in a specific state so I can test my dashboard logic.


### avoid wrapping

At Nubank we wrapped every 3rd-party library in our own API, which meant we:
 * could maintain mock implementations for testing
 * could ensure uniform and constrained usage over sometimes large 3rd-party libraries
 * often didn't really need to understand how the underlying library worked to use it

Looking at it now, it makes perfect sense for a large engineering team but doesn't exactly transfer to smaller teams.

Without much thought I was trying to apply the same approach at Nextjournal and was initially surprised at the pushback.
After some time on the team I'm starting to come around to the critiques, which are loosely:
 * the additional wrapper code we'd need to maintain might not justify the gains
 * we shouldn't run away from understanding how the underlying libraries work
 * rolling your own API is an opportunity to make design mistakes
 * don't implement more than you need; extra surface is always a liability

### the toolset

One last interesting point of resistence that I've appreciated from my new colleagues, as I've tried to port over my favorite things from Nubank, has been the resistence to increasing the tools surface area.

In particular, after a few years of using Kafka, or at least a heavily wrapped and abstracted version of it, everything to me looks like a nail that can be hammered in with it: Too many async operations, use kafka. Need to queue up notifications to be sent, use kafka.

So I keep bringing up in conversation how great it is and how we should use it for everything. And given the large-scale adoption of Kafka, I kind of expected my colleagues to chat me up about it and maybe give it a try.
Instead I've been met with skepticism over whether the complexity of such a tool is actually needed.

My colleagues have taken to asking me "is it possible to solve the problem using tools we already have; like just Datomic and threads?".
And so with some sketching we'll come up with a cute datomic-backed solution for sending notifications reliably.
When I come back to them with a prototype, that covers all the bases like retry and timeout logic, they'll challenge me with "we probably don't need retries or timeouts in this context, let's leave out that complexity and add it later if needed".

## to wrap up

In all it has been a very interesting and informative shift from coding at Nubank to coding at Nextjournal.
The contexts are clearly very different, in terms of both team size and product reliability needs.
Yet I've still been surprised at how much I've needed to unlearn or adapt in terms of how I approach Clojure and style the code I write.
Regardless, it had really made me appreciate and understand better why things were the way they were at Nubank.
And has me excited for my experiences to come at Nextjournal.

