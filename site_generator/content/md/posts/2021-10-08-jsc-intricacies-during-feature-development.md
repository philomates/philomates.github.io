{:title "JavaScriptCore Intricacies During Feature Development"
 :layout :post
 :description "How to get test coverage and debug a new JS feature in JavaScriptCore"
 :tags  []
 :toc false}

In the last post I talked about the Shadow Realm proposal and how I implemented it in JSC.

Today I'd like to expand a bit on the development process of working on new features in JavaScriptCore, WebKit's JS engine, as well as go into testing, experiences debugging performance issues, and some JSC abstractions that tripped me up.

This post is a bit of a mix of topics; we'll cover:
 - [test coverage](#test-coverage)
 - [exception handling](#exception-checking-in-jsc)
 - [OOM and GC issues](#debugging-arm-out-of-memory-woes)

## test coverage

When implementing new features in JSC it is helfpul to know what type of test coverage you need to get the patch landed.

With the shadow realms implementation, I was initially relying on [`test262` coverage](https://github.com/tc39/test262/tree/main/test/built-ins/ShadowRealm) that [Leo Balter](https://twitter.com/leobalter/) and [Rick Waldron](https://twitter.com/rwaldron) developed. [`test262`](https://github.com/tc39/test262/) is the implementation conformance test suite for TC39 features, which is a part of the TC39 proposal process and ultimately incorporated into the various browsers' test suites.

While `test262` tests run via the JSC console will give you nice coverage of the feature, you still need to use other tools to exercise the various levels of the JS engine, which in JSC is generally done with tests in the `JSTest/stress/` directory.

Let's get into both of these for a bit.

### test262

`test262` is developed in its own repository and then the different browsers import changes at their own descretion. Rick Waldron has a [nice post](https://bocoup.com/blog/new-test262-import-and-runner-in-webkit) explaining how the JSC project imports and runs `test262` tests.

Since I put `ShadowRealm` behind a feature flag [here](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-6c397225d0cc748e7f8a234d864cd4a4acd3df1ecffbc49e54973e91fe5cad11R1265-R1266), I needed to tell `test262` in `JSTests/test262/config.yaml` to use the `--useShadowRealm` flag when executing relevant tests [here](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-1a369f183a44ae6e8e9850fd25b85798b9e74ddc9f91b8cdb1435513050c3fc5R12).

With that, and making sure I had imported the most recent shadow realm suite changes from the `test262` repository, I was able to run the suite over my build of jsc relatively quickly with:

```
$ Tools/Scripts/test262-runner --debug --feature ShadowRealm --jsc WebKitBuild/Debug/bin/jsc
```

### stress

Turns out that getting all green on a `test262` isn't enough though, even if it comprehensively exercises the expected behavior of the new feature.
JSC has many development flags that can turn on validation checks, trigger or disable different tiers of the JIT, and force caching.
The `run-javascriptcore-tests` script is a harness that comprehensively explores all these flags.
In order to have your implementation accepted by reviewers you should add test coverage that is exercised by this script.

In this case I added a few files to `JSTest/stress`, which is more or less an unstructured directory of test files, at least as far as I can tell.

[`shadow-realm-evaluate.js`](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-b9d496009207df65cd754d33dd7c9ab9242e1edc0ed0c6f302d73935097a807c) adds standard behavioral coverage for `ShadowRealm.prototype.evaluate` along with a few expressions that are repeated thousands of times (in big `for`-loops) to trigger various JIT optimizations. [`shadow-realm-import-value.js`](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-ec9bbc8fd12b94135fdd54058ac6ce7c3f122cd671e50a4908beb381c70e8466) is roughly the same for `ShadowRealm.prototype.importValue`.

You can test for validity of your tests via a quick vanilla evaluation:

```
$ Tools/Scripts/run-jsc --jsc-only --debug --useShadowRealm=True JSTests/stress/shadow-realm-evaluate.js
```

and then to use the (really slow) harness that fully explores all the flags for turning on validations and specific compiler tiers:

```
$ Tools/Scripts/run-javascriptcore-tests --jsc-only --debug --no-build --filter="shadow-realm-*.js"
```

When I did this for shadow realm I discovered several issues

## bytecode cache issues

The first issue that surfaced from adding stress test coverage was that my `evaluate`-related code didn't play nice with the bytecode cache.
It took me a while to figure out what the trick was to reproduce the issue.

First you need to create a cache location and populate it:

```
$ mktemp -d -t bytecode-cacheXXXXXX
/tmp/bytecode-cacheJzazAI

$ Tools/Scripts/run-jsc --jsc-only --debug --useFTLJIT=false --useFunctionDotArguments=true \
                        --validateExceptionChecks=true --useDollarVM=true --maxPerThreadStackUsage=1572864 \
                        --useFTLJIT=true --useShadowRealm=1 JSTests/stress/shadow-realm-evaluate.js \
                        --diskCachePath=/tmp/bytecode-cacheJzazAI
```

Then you force usage of the cache by adding the `--forceDiskCache` flag:

```
$ Tools/Scripts/run-jsc --jsc-only --debug --useFTLJIT=false --useFunctionDotArguments=true \
                        --validateExceptionChecks=true --useDollarVM=true --maxPerThreadStackUsage=1572864 \
                        --useFTLJIT=true --useShadowRealm=1 JSTests/stress/shadow-realm-evaluate.js \
                        --diskCachePath=/tmp/bytecode-cacheJzazAI --forceDiskCache=1
```

With that setup you can interate more quickly on bytecode cache related issues without relying on the slowness of the whole harness.

And in the case of my issue: I was using an improper code path for evaluation. Once I realized this and adapted my code to use the code path for the standard indirect eval implementation, this issue went away.

## exception checking in JSC

The second issue that cropped up was with handling exceptions in C++ part of my implementation. As soon as I turned on the `--validateExceptionChecks` flag I started getting many issues like this:

```
ERROR: Unchecked JS exception:
    This scope can throw a JS exception: operator() @ Source/JavaScriptCore/runtime/IndirectEvalExecutable.cpp:83
        (ExceptionScope::m_recursionDepth was 6)
    But the exception was unchecked as of this scope: createImpl @ Source/JavaScriptCore/runtime/IndirectEvalExecutable.cpp:42
        (ExceptionScope::m_recursionDepth was 5)
```

As far as I understand, this validation failure is result of not properly doing a certain exception book-keeping dance.
Instead of the `try`-`catch` manner of exception handling, JSC relies on a few custom macros (such as `DECLARE_THROW_SCOPE`, `RETURN_IF_EXCEPTION`, `RELEASE_AND_RETURN`). These macros help ensure you explicitly consider any JS exceptions that can arise from calling into a function that can throw.

This is consideration is needed because JS exceptions inside the JSC engine don't explicitly interrupt the C++ control flow, like normal C++ exceptions, but are rather registered with the VM instance.
Exceptions are encountered nonetheless and thus subsequent logic usually needs to respond to their presence, hence all these macros to help with this.

To start let's see how throw scope objects help you know when a function can throw.

### throw scopes

You can loosely know if a C++ function can throw a JS exception if a throw scope is declared within it.

From the `ThrowScope` class:

```
// If a function can throw a JS exception, it should declare a ThrowScope at the
// top of the function (as early as possible) using the DECLARE_THROW_SCOPE macro.
// Declaring a ThrowScope in a function means that the function may throw an
// exception that its caller will have to handle.
```

Hence, in lots of places you'll see the following, which declares that in the current C++ scope, a JS exception can arise:

```c++
auto scope = DECLARE_THROW_SCOPE(vm);
```

If your code throws an exception but doesn't create a throw scope beforehand, the next piece of code that executes anything related to throw scopes will probably fail a validation check.

Note that `auto` is used here to signify that you shouldn't pass the `scope` object around, given that it is only relevant to the current C++ scope.
This is especially relevant because scope validation checks make use of the "resource acquisition is initialization" (RAII) pattern, and having destruction tied to a particular C++ scope is important.

### aborting after an exception

If you write some code that calls a function that can result in a JS exception, you need to make sure you act accordingly afterwards. This is done by using the aforementioned macros to check if an exception is "thrown", or that is, has been registered with the VM.
This is most commonly done with the `RETURN_IF_EXCEPTION` macro, looking something like

```c++
fnThatMayThrow();
RETURN_IF_EXCEPTION(scope, { });
```

This says if an exception has been registered, immediately return an empty JSValue instance (as interpreted from the `{ }` value in this context).

`RELEASE_AND_RETURN` is another related macro you might see sometimes. It is shorthand for

```c++
auto result = attemptSomeCalculation();
RETURN_IF_EXCEPTION(scope, result);
return result;
```

Which can then be written `RELEASE_AND_RETURN(scope, attemptSomeCalculation());`. It can be used in the place of a `return` and says that the second argument expression might throw but the next level up will react accordingly. Under the hood it is using a `scope.release()` to ignore some of the exception validation checks that happen when that particular `scope` object is destructed.

### handling an exception

But what if you want to actually run some logic after an exception has been registered?
This can be done using the pattern:

```c++
auto result = attemptSomeCalculation();
if (UNLIKELY(scope.exception())) {
    scope.clearException();
    // custom handling logic: in this case re-throw the exception with an adapted message
    return throwVMError(globalObject, scope, createTypeError(globalObject, "Error encountered during evaluation"_s));
}
RELEASE_AND_RETURN(scope, result);
```

Note that `UNLIKELY` is a branch-prediction hint that helps the compiler preduce more optimized code.

### catch scopes

Utilized less frequently are catch scopes (`DECLARE_CATCH_SCOPE`), which signal a scope where exceptions are accessed and cleared, yet new ones cannot be registered.
With this the engine can for instance take registered JS exceptions and output them to the user.

## debugging (ARM) out-of-memory woes

With stress tests running and my scope issues resolved I submitted my patch to the JSC review system, which triggered an EWS run (Early Warning System, WebKit's continuous integration). I had my share of random build issues to resolve, some not even due to my changes, but rather issues with the main branch (not sure how it gets in an unbuild-able state, but I guess it does). After that I ran into an OOM error while the CI ran the suite on some ARM machines.

Igalia maintains the 32-bit ARM version of WebKit and so we are the ones checking out these failures, so I figured I'd dive in and get a little more experience with the ARM side of things.

Of course when there is an out-of-memory error in a C++ code-base the first thought is: memory leak

### generating a heap dump

I started by trying to generate some sort of heap dump to see if it was infact a memory leak. You can do this by adapting your problematic JS test with

```javascript
... code leading to OOM issues

print(generateHeapSnapshotForGCDebugging().toString());
```

and then spitting that to a file:

```
$ Tools/Scripts/run-jsc --jsc-only --debug --useShadowRealm=True JSTests/stress/oom_issue.js > heap_dump.json
```

From there, open `Tools/GCHeapInspector/gc-heap-inspector.html` in your browser and drag in the `heap_dump.json` file to get an overview of the JS objects in the heap.

With this tool I started tweaking the number of iterations over allocate-related code and checking the resulting heap dump.
I didn't see any correpsondence between number of objects allocated and number of iterations, so I decided to move on to other techniques.

### evaluating performance by working backwards

Not really knowing what to do next to track down the OOM issue, I decided to work backwards and slowly disable features of `ShadowRealm.prototype.evaluate` until it started looking like a plain `eval`:
 - turned off callable boundary wrapping, which was easy because it was implemented in JS and required me to change things like `return @wrap(result)` to `return result`.
 - I made `evaluate` use the top-level global object instead of the realm's global object.
 - I disabled the removal of `name` and `length` properties from wrapped callables, which is part of making functions more opaque as they cross realm boundaries. This is implemented in JS via `delete wrapped['name']; delete wrapped['length'];` and while it didn't affect anything with how the callable was treated by the VM, the `delete` calls were actually really slow. Turns out `delete` doesn't have many optimizations for it in JSC yet; maybe something to explore in the future.

With all of these changes my implementation was effectively a glorified version of the standard JS `eval`, so why was it still so slow when compared to `eval`?!

After a pointer from a colleague, I started looking into the implementation difference between direct and indirect eval.

Direct eval being an eval that uses the scope of the caller, while indirect eval uses the top-level scope (for examples [see here](https://blog.klipse.tech/javascript/2016/06/20/js-eval-secrets.html)). Direct eval's implementation in JSC has a caching optimization that maps the call context to the fully parsed code related corresponding to the `eval` argument.
Indirect eval on the other hand doesn't have this optimization. I'm not exactly sure why that is, but it perhaps has to do with cache invalidation trickiness.
I asked some JSC implementors about this and they also said that running the same code over and over via `eval` is something to be discouraged, so having poor performance is acceptible in a sense.

The Shadow Realm `evaluate` spec says that it should use an indirect eval, which makes sense given that the caller is in an entirely different realm / has a different global object. Given this, I started digging into my implementation and verified that the JSC code I used is in fact the same as the indirect eval implementation. Hence there is no caching of parsed results. I then compared execution times of `ShadowRealm.prototype.evaluate` against direct and indirect eval and found it to be in-line with the slowness of indirect eval.

At this point I thought, if `ShadowRealm.prototype.evaluate` is slow like indirect eval, then maybe indirect eval also has this OOM issue.

A quick run of the following on one of our ARM machines validated my assumption: the issue also affects indirect eval.

```javascript
for (var i = 0; i < 2000; ++i)
  (0, eval)("() => {}");

```

Also resulted with the problematic

```
Ran out of executable memory while allocating 1152 bytes.
```

### GC issues

I decided to try to get more granularity on when things were allocated and de-allocated.
A colleague shared that `--logExecutableAllocation=1` would log allocation information, which showed more and more objects being allocated without old objects being freed.
But why weren't they being freed?!
What would happen if I explicitly tried to free them?
Luckily JSC exposes hooks to allow you to trigger the garbage collector via `fullGC` which the jsc console exposes for debugging purposes.

I ran

```javascript
for (var i = 0; i < 2000; ++i) {
  (0, eval)("() => {}");
  fullGC();
}
```

and this time there was no crash!

What does that mean? Well, probably that the heuristics for when to trigger the GC somehow don't get some allocation information related to the indirect eval implementation. Turns out that this is something that comes up from time to time in different contexts and a colleague pointed me to a similar issue at https://github.com/tc39/proposal-weakrefs/issues/87

## wrap-up

In this second post about JSC feature development we covered how to get different types of test coverage, some trickiness with exceptions and scopes, as well as some approaches to exploring performance and memory issues.

That concludes my experiences so far with implementation work in JSC.

Hope you found it interesting and I'm looking forward to sharing more write-ups as I continue my experiences hacking on open source web compilers at Igalia.
