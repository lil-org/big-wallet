# Technical Notes

## Table Of Contents

1. [Branching](#branching)
2. [Task Description](#task-description)
3. [Repository structure](#repository-structure)
    1. [Main application targets structure](#main-application-targets-structure)
    2. [Shared targets structure](#shared-targets-structure)
4. [Application Architecture](#application-architecture)
    1. [Features](#features)
    2. [Services](#services)
    3. [Ledgers](#ledgers)


## [Branching](#table-of-contents)

We are going for a simplified version of a [standard(code name: successful)](https://nvie.com/posts/a-successful-git-branching-model/) git flow model:

* **master** - last actual release in app store
* **origin/develop** — main development branches, we pour there feature branches, bug-fixes, issues. Since we are currently in a rapid development state, so fore time-being this is really unstable.
* **origin/release** — release branch for prepairing release to AppStore(i.e. getting ready for master update);
* **origin/release/x.x.x** — old-releases.

## [Repository structure](#table-of-contents)

* __Shared__: Subset of functionality that is shared between all targets.
    - Mostly includes constants, shared models and app-wise configurations.
* __Tokenary *__: Here goes everything targeting our main application
    * __Tokenary Shared__: Code aiming for cross-Apple-platform. 
        - Beware, there are many conditional imports.
        - Also when adding new functionality, ensure it supports all platforms. 
    * __Tokenary iOS__, __Tokenary macOS__: Code for **iOS** and **macOS** platforms reperspectively. 
* __Safari *__: Safari extension structure pretty much copies the main applications'.
    - The biggest difference is that concrete platform folders contain only configuration files and _JavaScript_ code.

### [Main application targets structure](#table-of-contents)

There is not much to talk about __Safari *__ targets structure, so lets solely focus on main application and shared. 

Platform specific targets are structured as follows: 
* __Core__: Stuff related to app launch.
* __Features__: Application screens.
    - Read more [here]().
* __Library__: Platform specific wrappers for some functionality with better interfaces.
    - Something smaller than service, but has concrete purpose and not suited as extension.
* __Extensions__: Extensions specific to this platform.
    - 99% of them have **NS**/**UI** prefix for _macOS_ or _iOS_ platforms respectively.
* __Generated__: Here goes the stuff we generate from resources bundle, to have strong type availability.
    - In future releases will include Fonts, Images, Colors and Strings.
* __Resources__: Files to be placed in **Resources Bundle**(during the Copy Bundle Resources building phase). 
    - Ideally, here lies _everything_ that goes to bundle, and not just general things.
* __Supporting Files__: Everything else, that didn't fit into previous categories.
    - Includes, but not limited to _Entitlements_, _*.plists_, _*-Bridging-Header.h_.

Also there is a folder for Model in __Tokenary macOS__, that holds some platform depended structures. 
However we are going to nerf that in future releases as soon as that companion-logic will become available on iOS/iPadOS.

### [Shared targets structure](#table-of-contents)

__Tokenary Shared__ structure: 

* __Features__: Application screens.
    - ⚠️_Warning_⚠️ - _SwiftUI_ code here. 
    - Read more [here]().
* __Models__: Domain-level models.
* __Ledgers__: Ledger-related abstractions.
* __Services__: Service abstraction, that wraps conmimications with external world, databases, periferia, etc. ...
    - Or pretty much anything that can be considered an effect action upon some-medium which returns some kind of promise.
    - For service structure dissemination, read [here]().
* __Wallets__: Private-key derivations and everything related to it(storing, retrieving, updating).
* __Extensions__: Extensions available to both platforms.
* __Helpers__: Read as _library_ functionality that is available to all platforms. 
* __Generated__, __Resources__, __Supporting Files__: Usual stuff, that lies in shared space.

__Shared__ structure: 

* __CollectionsOf__: Here lies code 
* __Atoms__: 
* __Models__: Shared domain models(but actually think DTOs here).
* __Supporting Files__: Small list of configurations applicable to all targets.

## [Application Architecture](#table-of-contents)

TBD

## [Features](#table-of-contents)

Currently, we are shifting towards separating each logical user-story into self-containted flow which are called features.

This basically means, we want abstractions to be non-leaking(private view-models, shared domain logic, constrained interfaces, reliance on DI generation at build-time) and as a result of it, to be able to separate code into separate swift-module to improve build-concurrency when the necessity will arise.

Currently, we follow these rules: 
    - In *Common* folder go V/VC that are shared between at least 2 flows
    - Also there goes platform-specic wrappers. 
    - The folder structure, in case of necessity is duplicated in shared and platform specific targets.
        - This essentially means, if some functionality needs to have a platform specific code, that can't be 
        solved with _macros_, the feature folder is created in each target and naming for files must be the same.
    - Feature structure:
        - _Assembly_: builds the feature use-case, configures dependencies and returns the VC to use.
        - TBD. 

## [Services](#table-of-contents)

TBD

## [Ledgers](#table-of-contents)

TBD