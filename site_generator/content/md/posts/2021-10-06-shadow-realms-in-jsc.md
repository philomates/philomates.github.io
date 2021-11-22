{:title "Hanging in the Shadow Realm with JavaScriptCore"
 :layout :post
 :description "An introduction to implementing new JS features in JavaScriptCore"
 :tags  []
 :toc false}

I'm super excited to have recently joined the Compilers team at [Igalia](https://www.igalia.com/); a pretty unique place for many reasons. One of those is the fact that we do work on all three of the main JavaScript engines: Chromium's V8, WebKit/Safari's JavaScriptCore (JSC), and Firefox's SpiderMonkey.

When I initially joined in August 2021, I started with some exploratory escape analysis optimization work in V8 JS engine. We shelved that work for now and I jumped over to my first proper project: implementing the Shadow Realm proposal in JSC.

With an initial implementation submitted for review, which was developed in collaboration with fellow Igalian [Caio Lima](https://caiolima.github.io/), I figured it would be a good time to explain a bit about Shadow Realms and how to implement new JavaScript features in JSC.

## The Shadow Realm

Before we get into some JSC internals, let's have some context on the feature itself.

[Shadow Realms](https://github.com/tc39/proposal-shadowrealm/blob/main/explainer.md) is a new JS isolation primitive being proposed in TC39 that can be used for building more reliable isolation and sandboxing libraries.

Igalia's work on the Shadow Realm implementation is in partnership with SalesForce. As a platform on the web, SalesForce allows users to share and run custom code, thus proper isolation primitives in JavaScript are of particular interest to SalesForce. Over several years SalesForce, Igalia, and other TC39 contributors iterated on and refined the Shadow Realm proposal. When it came time to implement the proposal in various JavaScript engines, SalesForce sponsored our team to work on it.

### background

JS is a pretty dynamic place to hang, to say the least. When you load code from various libraries there is always the possibility that they patch something in the prototype chain in a way that is dangerous to other libraries. If you have control over the libraries you're including, you can audit and test things to mitigate this. On the otherhand if you want to have a user-contributed plugin system, a reliable testing environment, or things like DOM virtualization ([more context here](https://github.com/tc39/proposal-shadowrealm/blob/main/explainer.md#use-cases)), you need proper isolation primitives.

It turns out that providing code evaluation isolation in pure JavaScript is very difficult. Figma has [a nice blog post](https://www.figma.com/blog/how-we-built-the-figma-plugin-system/) exploring some of these difficulties and [how they ran into issues](https://www.figma.com/blog/an-update-on-plugin-security/) with an early JS-based Shadow Realm shim. Another focused effort on sandbox and isolation in JS is SalesForce's Lightning Locker.

JavaScript iframes are an existing way to offer some level of isolation but they can be heavy-weight and tricky to use. Web workers are another alternative but only offer asynchronous execution which isn't compatible with the APIs that most 3rd party plugin systems want to provide. Hence the investment in developing a new JS isolation primitive.

### basic API

A Shadow Realm is an object that, when created, constructs a fresh global object, and hence a fresh prototype chain. With the API you can evaluate code in the context of the realm's global object using `evaluate` and module code using `importValue`:

```javascript
declare class ShadowRealm {
    constructor();
    evaluate(sourceText: string): PrimitiveValueOrCallable;
    importValue(specifier: string, bindingName: string): Promise<PrimitiveValueOrCallable>;
}
```

For example:

```javascript
globalThis.secret = 123;
let realm = new ShadowRealm();

let innerSecret = realm.evaluate('globalThis.secret = 456; secret;');
secret !== innerSecret // as in: 123 !== 456

let runPlugin = await importValue("./some-plugin.js", "run");
runPlugin();
```

In short
 - `evaluate` is sort of like `eval` but using the running the code in the context of the realm's global object.
 - `importValue` is a bit of a mix of the dynamic `import()` function and top-level `import { export1 } from "module-name";`

### the callable boundary

So `ShadowRealm.prototype.evaluate` gives us code evaluation isolation by running code in the context of a fresh global object but what about communication between different realms? Initially the Shadow Realm proposal allowed for many things to be passed between realms. Yet closer investigation showed that if objects are passed between realms, it isn't so hard to leak the outer realm's global object to the inner one ([detailed here](https://github.com/tc39/proposal-shadowrealm/issues/277)), thus breaking all the isolation guarantees because then you can mutate other realm's prototype chains.

The proposal was subsquently revised to constrain what information can be passed between realms. Only primitives and wrapped callables would be allowed, but passing around objects would result in type errors. This restriction was put in place to prevent users from accessing and potentially mutating other realm's prototype chain, which could be obtained through the objects or functions being passed between them.

Thus in the proposal's spec when a function from the inner realm `B` is returned to the outer realm `A`, it is wrapped in a closure created using `A`'s global object, hiding access to the original function and the `B` global object it is associated with.

And what happens when you invoke the wrapped callable with arguments from the other side of the boundary, or use the return value it provides? Well, those arguments and return values also need to be either primitives or wrapped callables themselves, with everything else resulting in a type error.


In a way, only being able to pass around primitives and functions is pretty constraining. That is why Shadow Realms is seen more as a tool for library builders to create more expressive sandbox / isolation tools on top of.

## The JSC implementation

Recently, after a couple years of discussion, adaption, and refinement, the Shadow Realm proposal reached [stage 3](https://tc39.es/process-document/) as a TC39 proposal. In stage 3, the main thing left reach the last TC39 stage is to implement the feature in 2 major web browsers.

At Igalia we've been working with SalesForce on Shadow Realms. They've put a lot of work into the proposal and are excited about how it could help them with sandboxing tools like Lightning Locker. And given our expertise on JS engines, we were happy to work with them on the WebKit/JSC implementation, which is how I got invovled.

### implementation options

In JSC you can implement JS features using 2 approaches (or a mix of them):
 - using self-hosted JS built-ins: this allows the code you write to be optimized by the compiler itself, but also means you can't really use a stepping-debugger during dev. And, as we'll see, some functionality can't (easily) be implemented in JS.
 - in C++ host functions: you have more control over what your implementation does if you write it at the host C++ level. Its also compatible with gdb/lldb, though more verbose/unreadable than a JS implementation. Note that it can be less performant because you don't have a nice JIT compiler to optimize things.

I got started on a C++ implementation first because we weren't really sure what would be needed in terms of expressiveness for the implementation.

### the C++ approach

The main tricks to the Shadow Realms implementation was to create a new global object to do evaluation in, and also ensure that the callable boundary was adequately enforced.

The pure C++ implementation I did entailed creating the following internal classes and functions represent the Shadow Realm API:

 - `ShadowRealmObject`: represents a `ShadowRealm` JS object. Its prototype (`__proto__` property) is set to `ShadowRealmPrototype` and it also holds on to the new global object associated with the realm.
 - `ShadowRealmConstructor`: represents a sort of internal construction function used to build new `ShadowRealm` objects.
 - `ShadowRealmPrototype`: contains the main functionality (`evaluate` and `importValue`) as host functions. The core evaluation and module loading logic was copied from other parts of JSC. Turns out there are many different entry points to both evaluation and module loading code and it is hard to know the right one to use. More on that later.
 - `ShadowRealmWrappedFunction`: represents an "exotic" (as in, non-standard) JS callable; extending JSC's `JSFunction` class. When called it checks that arguments and return values are primitives or wrapped in `ShadowRealmWrappedFunction` callables themselves.

(This approach is reflected in these commits: [[1](https://github.com/WebKit/WebKit/commit/9a72749bf1dc13b02cde128c6bf194eacaad7ab6), [2](https://github.com/WebKit/WebKit/commit/98130b8253cdb5bbe3dec2ac860b799b8f717f1e)]. Note that this was a proof-of-concept and what I refer to as `ShadowRealmObject` above was really `ShadowRealm` in the commits)

Creating a new global object was straightforward to setup ([code link](https://github.com/WebKit/WebKit/commit/9a72749bf1dc13b02cde128c6bf194eacaad7ab6#diff-c7057ee151b8f4e72ba599a4eb7f1cbfcab15e32fbd1660853bf8aa73fd9cbbcR56-R57)), given that the normal JSC process needs to do this on startup.

Enforcing the callable boundary meant wrapping functions passed between realms with boundary-checks that are made when the function is invoked. I looked for other instances where functions might be wrapped and found that `bind` JS feature, which allows for partial argument application, fit that criteria. A bulk copy-and-rename of the `bind` implementation in JSC got me to a working implementation ([code link](https://github.com/WebKit/WebKit/commit/9a72749bf1dc13b02cde128c6bf194eacaad7ab6#diff-6b88bb093382d8d3ea5bd4636b653ecd2dceb06f4719ff52f96468bd6fa5da89))

With these existing examples to draw from I was able to stumble my way into a working implementation. From there, we at Igalia shared the approach with the JSC team at Apple. In talking with them we learned that `JSBoundFunction`, of which I based `ShadowRealmWrappedFunction`, isn't really optimized in the different JIT tiers. Thus, my wrapped functions also wouldn't be, at least without a bunch of extra work.

The Apple JSC team had a unsubmitted patch to reimplement `bind` using JS built-ins, by way capturing bound arguments via closure functions, to re-use normal VM optimizations for JS functions. They suggested also trying to implement shadow realms and boundary-check wrappers using the JS built-in approach.

### the JS built-ins approach

The JSC VM is written in C++, so you can naturally do all your implementation work there. The other option though is to register JS code (JS built-ins) as implementations.

So for instance, earlier in the C++ version we registered the implementation for `ShadowRealm.prototype.evaluate` and `ShadowRealm.prototype.importValue` [like this](https://github.com/WebKit/WebKit/commit/9a72749bf1dc13b02cde128c6bf194eacaad7ab6#diff-bc93bf5bf17a9cf421eccdcf9a9d2e9ea2e0848ebc6095019cf0d7d719260bc6R34-R35). Adapting the implementation to a JS built-in version, we'd then have something [like this](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-e2238cb47ef2f02dfb6ee7931d65ef54f9abaf17c04d853be882aa735fb60f91R42-R45), which points to [`builtins/ShadowRealmPrototype.js`](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-8738ecbd2550f772286c7dc71027232a17ea365e92407da5050f844bc4f25b11R46-R84).

Seems pretty weird to implement parts of JS in JS itself, right?

Well since we have a highly-optimized JS VM at hand (even if we are in fact in the middle of implementing it) we might as well use all its optimizations by writing in JS itself. Thus if we implement JS features using other heavily optimized JS features, we transitively get the benefits of those optimizations.

V8 also took this approach in the past but deprecated it in favor of CodeStubAssembler and Torque ([this post has some context](https://v8.dev/blog/csa#a-brief-history-of-builtins-and-hand-written-assembly-in-v8))

#### JS built-ins calling host C++ code

In terms of implementing the Shadow Realms spec, some things can be implemented as JS built-ins and benefit from doing so, such as the callable bounadary wrappers. Yet other aspects can't really be expressed in JS and require work at the C++ level, such as creation of custom global objects, as well as evaluating code in the context of these particular global objects. Thus it is helpful to be able to call back and forth from both.

The JS-based implementation of `ShadowRealm.prototype.evaluate` first calls to the `@evalInRealm` host function that we implement in C++ [here](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-e2238cb47ef2f02dfb6ee7931d65ef54f9abaf17c04d853be882aa735fb60f91R86). This implementation allows us to use the shadow realm instance's global object in non-standard ways, like as the context with whitch to do code evaluation. The result of this code evaluation is then wrapped using `@wrap`, which is also a JS-based implementation defined [here](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-8738ecbd2550f772286c7dc71027232a17ea365e92407da5050f844bc4f25b11R26-R44).

The `evaluate` implementation:

```javascript
function evaluate(sourceText)
{
    "use strict";

    if (!@isShadowRealm(this))
        @throwTypeError("`%ShadowRealm%.evaluate requires that |this| be a ShadowRealm instance");

    if (typeof sourceText !== 'string')
        @throwTypeError("`%ShadowRealm%.evaluate requires that the |sourceText| argument be a string");

    let result = @evalInRealm(this, sourceText)
    return @wrap(result);
}
```


#### protecting yourself from prototype-chain pollution

In JS you can redefine pretty much everything, so if your VM implement one JS feature in terms of other (redefinable) JS features, then the VMs behavior is at the mercy of the user code it loads. To protect against this, JSC has special protected versions of core JS functionality, starting with an `@` character.

For instance, I initially implemented function wrapping using the default `Array.prototype.map` and `Function.prototype.apply`:

```javascript
function wrap(targetFunction) {
    ...
    let wrapped = (...args) => {
        // recursively wrap arguments coming into the wrapped function
        var wrappedArgs = args.map(@wrap)
        // run the underlying function
        const result = targetFunction.apply(@undefined, wrappedArgs);
        // wrap the result
        return @wrap(result);
    ...
};
```

These can be redefined at runtime, which is dangerous. I thus later updated them to `args.@map(@wrap)` and `targetFunction.@apply(@undefined, wrappedArgs)` respectively. The protected version of `Array.prototype.map`, `@map`, wasn't actually exposed beforehand, but it was easy to enough to make avaiable with [this](https://github.com/WebKit/WebKit/compare/main...philomates:shadow-realm-patch-iii?expand=1#diff-6b24e225993b3ab3229b57e9279aae265badb1c9fd28f1a07d060073ecee8bf9R108)


#### a build gotcha: changes to a JS built-in are ignored

At various points during the development of `builtins/ShadowRealmPrototype.js` I my changes weren't included in re-builds I triggered.

It is pretty hard to iterate on subtle issues when you aren't sure if your code changes were in fact loaded. Traditional step debugging won't help you out here, but since wrapping up this work I've discovered that you can do print-statement debugging in JSC via `@$vm.print` expressions, given you use the `--useDollarVM=1` flag.

Regardless, the "fix" I found to ensure JS built-in changes were registered was to turn off `ccache` by passing the `--no-use-ccache` to the `build-webkit` script. This made building much slower, but seemed to help. If you know what's going on here, I'd love some tips!

## Wrap-up

Hopefully that gives you a feel for a bit of what it takes to implement a new JS feature in JavaScriptCore. My initial ShadowRealm implementation is up at [https://bugs.webkit.org/show_bug.cgi?id=230602](https://bugs.webkit.org/show_bug.cgi?id=230602) if you're curious to check it out in more detail.

With this background context out of the way, I'm looking forward to talking a bit about other things I came across during this work. Mainly how I tested the implementation, some issues I ran into with handling scopes in JSC, and things I learned while digging into performance issues.
