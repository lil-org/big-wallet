import {readFile} from "node:fs/promises";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
import vm from "node:vm";
import {createPopupHarness} from "../../Safari Shared/Tests/popup_harness.mjs";
import {LifecycleFailure} from "./scheduler.mjs";

const providerRequire = createRequire(new URL("../../Safari Shared/Inpage Provider/package.json", import.meta.url));
const {buildSync} = providerRequire("esbuild");
const base58Module = providerRequire("bs58");
const base58 = base58Module.default || base58Module;
const resources = new URL("../../Safari Shared/Resources/", import.meta.url);
const sourceNames = ["protocol.generated.js", "bridge_wire.js", "content.js", "service_worker.js"];
const sources = new Map(await Promise.all(sourceNames.map(async name => [name, await readFile(new URL(name, resources), "utf8")])));
const providerSource = buildSync({
    entryPoints: [fileURLToPath(new URL("../../Safari Shared/Inpage Provider/index.js", import.meta.url))],
    bundle: true, format: "iife", platform: "browser", target: "safari15", write: false, logLevel: "silent",
}).outputFiles[0].text;
const extensionID = "wallet-extension";
const extensionURL = "safari-web-extension://wallet/";
const clone = value => value === undefined ? undefined : structuredClone(value);
const never = () => new Promise(() => {});

function publicProviderState(document, provider) {
    return provider === "ethereum" ? {address: document.pageWindow.ethereum.selectedAddress || "", chainId: document.pageWindow.ethereum.chainId} :
        {publicKey: document.pageWindow.solana.publicKey?.toBase58() || ""};
}

function publicBytes(value) {
    if (value instanceof ArrayBuffer) { return Buffer.from(value); }
    if (ArrayBuffer.isView(value) && value.BYTES_PER_ELEMENT === 1) {
        return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
    }
    throw new LifecycleFailure("payload", "Dispatched Solana request has no original public bytes");
}

function publicRequestBody(operation, dispatchedState, wireID) {
    const {method, params} = operation.payload;
    const state = operation.publicState.address || operation.publicState.publicKey ? operation.publicState : dispatchedState;
    if (operation.provider === "ethereum") {
        let object, address = state.address;
        if (method === "personal_sign") { object = {data: clone(params[0])}; address = params[1] || address; }
        else if (["eth_signTypedData", "eth_signTypedData_v3", "eth_signTypedData_v4"].includes(method)) {
            object = {raw: clone(params[1])}; address = params[0] || address;
        } else if (method === "eth_sendTransaction") { object = clone(params[0]); address = object.from || address; }
        else if (method === "personal_ecRecover") { object = {message: clone(params[0]), signature: params[1]}; }
        else { object = clone(params?.[0] || {}); }
        return {address, chainId: state.chainId, object};
    }
    const encoded = value => typeof value === "string" ? value : base58.encode(publicBytes(value));
    let normalized = clone(params);
    if (method === "signMessage") {
        const utf8 = typeof params.message === "string" && typeof params.display === "string" && params.display.toLowerCase() === "utf8";
        const message = utf8 ? params.message : typeof params.message === "string" ? "0x" + params.message.replace(/^0x/, "") :
            "0x" + publicBytes(params.message).toString("hex");
        normalized = {...normalized, message, messageEncoding: utf8 ? "utf8" : "hex"};
    } else if (method === "signTransaction") { normalized = {message: encoded(params.message)}; }
    else if (method === "signAllTransactions") { normalized = {messages: (params.messages ?? params.message).map(encoded)}; }
    else if (method === "signAndSendTransaction") {
        normalized = params.transaction === undefined ? {message: encoded(params.message)} : {transaction: encoded(params.transaction)};
        if (params.options !== undefined) { normalized.options = clone(params.options); }
    }
    return {publicKey: state.publicKey, object: {id: wireID, method, ...(normalized === undefined ? {} : {params: normalized})}};
}

export function requestNameForOperation(operation) {
    const method = operation.payload.method;
    if (operation.provider === "solana") {
        return ["connect", "signMessage", "signTransaction", "signAllTransactions", "signAndSendTransaction"].includes(method) ? method : undefined;
    }
    const names = {eth_requestAccounts: "requestAccounts", wallet_requestPermissions: "requestAccounts", personal_sign: "signPersonalMessage",
        personal_ecRecover: "ecRecover", eth_signTypedData: "signTypedMessage", eth_signTypedData_v3: "signTypedMessage",
        eth_signTypedData_v4: "signTypedMessage", eth_sendTransaction: "signTransaction",
        wallet_addEthereumChain: "addEthereumChain", wallet_switchEthereumChain: "switchEthereumChain"};
    return operation.provider === "ethereum" ? names[method] : undefined;
}

function matchesOperationTransport(operation, envelope) {
    const method = operation.payload.method;
    if (envelope.kind === "disconnect") {
        return method === (operation.provider === "ethereum" ? "wallet_revokePermissions" : "disconnect");
    }
    if (envelope.kind === "rpc") {
        try { return JSON.parse(envelope.message.body).method === method; } catch { return false; }
    }
    if (envelope.kind !== "request") { return false; }
    if (operation.provider === "solana") { return envelope.message.body?.object?.method === method; }
    return requestNameForOperation(operation) === envelope.message.name;
}

class BrowserEvent {
    constructor(type, options = {}) { this._type = type; Object.assign(this, options); }
    get type() { return this._type; }
}
class BrowserCustomEvent extends BrowserEvent {
    constructor(type, options = {}) { super(type, options); this.detail = options.detail; }
}

function listeners() {
    const values = new Map;
    return {
        addEventListener(name, listener) { if (!values.has(name)) { values.set(name, []); } values.get(name).push(listener); },
        removeEventListener(name, listener) { values.set(name, (values.get(name) || []).filter(value => value !== listener)); },
        dispatch(name, event, receiver) { for (const listener of [...(values.get(name) || [])]) { listener.call(receiver, event); } },
        count(name) { return values.get(name)?.length || 0; },
    };
}

export class BrowserLifecycle {
    constructor({scheduler, native, mode = "native", trace = () => {}, onNative = () => {}, onSettlement = () => {}}) {
        this.scheduler = scheduler;
        this.native = native;
        this.mode = mode;
        this.trace = trace;
        this.onNative = onNative;
        this.onSettlement = onSettlement;
        this.profiles = new Map;
        this.tabs = new Map;
        this.operations = new Map;
        this.faults = [];
        this.serial = 0;
        this.tabSerial = 0;
        this.operationSerial = 0;
        this.errors = [];
        this.transportCounts = new Map;
    }
    addFault({channel, subject, phase = "request", action, delay = 1000, sourceAction, target}) {
        if (!["drop", "duplicate", "delay"].includes(action)) { throw new Error("Unknown browser fault"); }
        this.faults.push({channel, subject, phase, action, delay, sourceAction, target});
    }
    faultFor(channel, subject, phase, key) {
        const index = this.faults.findIndex(value => (!value.channel || value.channel === channel) &&
            (!value.subject || value.subject === subject) && value.phase === phase && (!value.target || value.target === key));
        return index < 0 ? null : this.faults.splice(index, 1)[0];
    }
    queue(owner, channel, phase, message, callback, replyTo) {
        const subject = message?.subject || message?.message?.name || message?.name || message?.kind;
        const transientID = ["getLatestConfiguration", "getRecoveryRequests", "getPendingRequests", "workflowProbe", "configurationInvalidated", "responseReady", "response", "pendingRequestAvailable"].includes(subject);
        const terminalPageReply = channel === "page" && phase === "reply" && message?.kind === "response" &&
            ["result", "error"].includes(message.response?.kind);
        const identity = replyTo || (terminalPageReply ?
            `${message.providerGeneration}:${message.response.provider}:${message.response.name}:${message.response.id}` :
            `${message?.configurationKey || ""}:${transientID ? "" : message?.id ?? message?.message?.id ?? ""}:${message?.enqueueAttempt || ""}`);
        const prefix = `${this.scheduler.phase}|${owner}|${channel}|${phase}|${subject}|${identity}`;
        const occurrence = (this.transportCounts.get(prefix) || 0) + 1;
        this.transportCounts.set(prefix, occurrence);
        const transportKey = `${prefix}|${occurrence}`;
        const fault = this.faultFor(channel, subject, phase, transportKey);
        this.trace({type: "browser-wire", owner, channel, phase, transportKey, message: clone(message), fault});
        if (fault?.action === "drop") { return transportKey; }
        const run = () => {
            try { callback(); }
            catch (error) { this.errors.push(error); }
        };
        const id = this.scheduler.schedule(run, fault?.action === "delay" ? fault.delay : 0, owner, "message", {channel, phase, subject, transportKey});
        if (fault?.action === "duplicate") { this.scheduler.duplicate(id); }
        return transportKey;
    }
    async nativeMessage(profile, owner, message, isLive) {
        if (!isLive()) { return never(); }
        const payload = clone(message);
        try { this.onNative({profileIdentifier: profile.id, owner, message: clone(payload)}); }
        catch (error) { this.errors.push(error); throw error; }
        return new Promise((resolve, reject) => {
            const callKey = this.queue(owner, "native", "request", payload, () => {
                if (!isLive()) { return; }
                Promise.resolve(this.native(payload, profile.id)).then(
                    reply => this.queue(owner, "native", "reply", payload, () => { if (isLive()) { resolve(clone(reply)); } }, callKey),
                    error => this.queue(owner, "native", "reply", payload, () => { if (isLive()) { reject(error); } }, callKey)
                );
            });
        });
    }
    profile(id = null) {
        const key = id ?? "default";
        if (!this.profiles.has(key)) {
            const profile = {id, storage: new Map, alarms: new Map, worker: null, popup: null, activeTab: null, workerSerial: 0, popupSerial: 0};
            this.profiles.set(key, profile);
            this.startWorker(profile);
        }
        return this.profiles.get(key);
    }
    startWorker(profile) {
        const owner = `worker:${profile.id ?? "default"}:${++profile.workerSerial}`;
        const worker = {owner, runtimeListeners: [], alive: true, installed: null, startup: null, alarm: null, toolbar: null};
        profile.worker = worker;
        const isLive = () => worker.alive && profile.worker === worker;
        const runtime = {
            id: extensionID,
            getURL: path => extensionURL + path,
            getManifest: () => ({version: "1.0.99", action: this.mode === "popup" ? {default_popup: "popup.html"} : {}}),
            onMessage: {addListener: listener => worker.runtimeListeners.push(listener)},
            onInstalled: {addListener: listener => { worker.installed = listener; }},
            onStartup: {addListener: listener => { worker.startup = listener; }},
            sendNativeMessage: (_application, message) => this.nativeMessage(profile, owner, message, isLive),
            sendMessage: message => new Promise(resolve => {
                this.queue(owner, "runtime", "request", message, () => {
                    if (profile.popup) { profile.popup.harness.notify(clone(message), {id: extensionID, url: extensionURL}); }
                    resolve(undefined);
                });
            }),
        };
        const browser = {
            runtime,
            extension: {inIncognitoContext: false},
            i18n: {getMessage: () => ""},
            alarms: {
                get: async name => clone(profile.alarms.get(name)),
                create: async (name, settings) => { profile.alarms.set(name, {...clone(settings), name, scheduledTime: this.scheduler.now + settings.delayInMinutes * 60000}); },
                clear: async name => profile.alarms.delete(name),
                onAlarm: {addListener: listener => { worker.alarm = listener; }},
            },
            storage: {local: {
                get: async keys => Object.fromEntries((Array.isArray(keys) ? keys : [keys]).filter(key => profile.storage.has(key)).map(key => [key, clone(profile.storage.get(key))])),
                set: async values => { for (const [key, value] of Object.entries(values)) { profile.storage.set(key, clone(value)); } },
                remove: async key => { profile.storage.delete(key); },
            }},
            action: {
                onClicked: {addListener: listener => { worker.toolbar = listener; }},
                setBadgeText: async value => { this.trace({type: "badge", profile: profile.id, ...value}); },
                setTitle: async () => {},
                openPopup: async () => { if (this.mode === "popup" && !profile.popup) { await this.openPopup(profile.id); } },
            },
            tabs: {
                query: async () => [...this.tabs.values()].filter(tab => tab.profile === profile && tab.alive).map(tab => ({id: tab.id, url: tab.url, incognito: tab.privateBrowsing})),
                sendMessage: (id, message) => this.toContent(id, message, {id: extensionID, url: extensionURL}, owner),
                onUpdated: {addListener: listener => { worker.tabUpdated = listener; }},
                onRemoved: {addListener: listener => { worker.tabRemoved = listener; }},
            },
        };
        const context = vm.createContext({browser, URL, console: this.console(owner), ...this.scheduler.bindings(owner),
            importScripts: (...names) => { for (const name of names) { new vm.Script(sources.get(name), {filename: name}).runInContext(context); } }});
        worker.context = context;
        new vm.Script(sources.get("service_worker.js"), {filename: "service_worker.js"}).runInContext(context);
        return worker;
    }
    console(owner) {
        return {log() {}, warn: (...args) => this.trace({type: "console", owner, args: args.map(String)}),
            error: (...args) => this.trace({type: "console", owner, args: args.map(String)})};
    }
    toWorker(profile, message, sender, owner, sourceLive = () => true) {
        const worker = profile.worker;
        const payload = clone(message);
        return new Promise(resolve => {
            const callKey = this.queue(owner, "runtime", "request", payload, () => {
                if (!sourceLive() || !worker.alive || profile.worker !== worker) { return; }
                let asynchronous = false;
                let answered = false;
                const respond = value => {
                    answered = true;
                    this.queue(owner, "runtime", "reply", payload, () => {
                        if (sourceLive() && worker.alive && profile.worker === worker) { resolve(clone(value)); }
                    }, callKey);
                };
                for (const listener of worker.runtimeListeners) { asynchronous = listener(clone(payload), clone(sender), respond) === true || asynchronous; }
                if (!asynchronous && !answered) { respond(undefined); }
            });
        });
    }
    toContent(id, message, sender, owner) {
        const tab = this.tabs.get(id);
        const document = tab?.document;
        if (!tab?.alive || !document?.alive) { return Promise.reject(new Error("No receiving content script")); }
        return new Promise(resolve => {
            const callKey = this.queue(owner, "tab", "request", message, () => {
                if (!document.alive || tab.document !== document) { return; }
                let asynchronous = false;
                let answered = false;
                const respond = value => {
                    answered = true;
                    this.queue(owner, "tab", "reply", message, () => { if (document.alive) { resolve(clone(value)); } }, callKey);
                };
                for (const listener of document.runtimeListeners) { asynchronous = listener(clone(message), clone(sender), respond) === true || asynchronous; }
                if (!asynchronous && !answered) { respond(undefined); }
            });
        });
    }
    openTab({id = ++this.tabSerial, profileIdentifier = null, url = "https://wallet.example/dapp", privateBrowsing = false} = {}) {
        const profile = this.profile(profileIdentifier);
        if (this.tabs.has(id)) { throw new Error("Tab already exists"); }
        const tab = {id, profile, url, privateBrowsing, alive: true, document: null, documentSerial: 0};
        this.tabs.set(id, tab);
        profile.activeTab = id;
        this.startDocument(tab);
        return tab;
    }
    startDocument(tab) {
        const owner = `document:${tab.id}:${++tab.documentSerial}`;
        const document = {owner, alive: true, runtimeListeners: [], events: [], pageEvents: listeners(), contentEvents: listeners(), domEvents: listeners()};
        tab.document = document;
        const location = new URL(tab.url);
        const dom = {
            doctype: {name: "html"}, documentElement: {nodeName: "HTML"}, currentScript: null, visibilityState: "visible",
            addEventListener: (...args) => document.domEvents.addEventListener(...args),
            createElement: () => {
                const attributes = new Map;
                return {textContent: "", setAttribute: (key, value) => attributes.set(key, String(value)), getAttribute: key => attributes.get(key) ?? null};
            },
        };
        const post = message => {
            const value = clone(message);
            if (value.direction === "big-wallet-provider-v1" && value.message) {
                const provider = value.kind === "rpc" ? "ethereum" : value.message.provider;
                const dispatchedState = publicProviderState(document, provider);
                queueMicrotask(() => {
                    const operation = [...this.operations.values()].find(candidate => candidate.document === owner &&
                        candidate.provider === provider && candidate.providerGeneration === value.providerGeneration &&
                        candidate.wireID === undefined && candidate.status === "pending" && matchesOperationTransport(candidate, value));
                    if (operation) {
                        operation.wireID = value.message.id;
                        operation.wireKind = value.kind;
                        if (value.kind === "request") {
                            try { operation.requestBody = publicRequestBody(operation, dispatchedState, value.message.id); }
                            catch (error) { this.errors.push(error); }
                        }
                    }
                });
            }
            const phase = value.direction === document.contentContext.bigWalletContentDirection ? "reply" : "request";
            this.queue(owner, "page", phase, value, () => {
                if (!document.alive || tab.document !== document) { return; }
                document.pageEvents.dispatch("message", {source: document.pageWindow, data: clone(value)}, document.pageWindow);
                document.contentEvents.dispatch("message", {source: document.contentWindow, data: clone(value)}, document.contentWindow);
                if (value.direction === document.contentContext.bigWalletContentDirection && value.response?.state &&
                    value.providerGeneration === document.contentContext.bigWalletProviderGeneration) {
                    document.deliveredConfiguration = {providerGeneration: value.providerGeneration, state: clone(value.response.state)};
                }
            });
        };
        const bindings = this.scheduler.bindings(owner);
        const pageWindow = {
            ...document.pageEvents, document: dom, location, navigator: {wallets: []}, crypto: bindings.crypto,
            postMessage: post,
            dispatchEvent: event => {
                document.pageEvents.dispatch(event.type, event, pageWindow);
                return true;
            },
        };
        const contentWindow = {...document.contentEvents, document: dom, location, postMessage: post};
        Object.assign(document, {pageWindow, contentWindow, dom});
        const pageContext = vm.createContext({window: pageWindow, document: dom, URL, Event: BrowserEvent, CustomEvent: BrowserCustomEvent,
            console: this.console(owner), ...bindings});
        document.pageContext = pageContext;
        dom.head = {
            children: [],
            insertBefore: script => {
                dom.currentScript = script;
                try { new vm.Script(script.textContent, {filename: "inpage.js"}).runInContext(pageContext); }
                finally { dom.currentScript = null; }
            },
            removeChild() {},
        };
        const sourceLive = () => document.alive && tab.document === document;
        const sender = () => ({id: extensionID, url: tab.url, frameId: 0,
            tab: {id: tab.id, url: tab.url, incognito: tab.privateBrowsing}});
        const browser = {runtime: {
            id: extensionID, getURL: path => extensionURL + path,
            onMessage: {addListener: listener => document.runtimeListeners.push(listener)},
            sendMessage: message => this.toWorker(tab.profile, message, sender(), owner, sourceLive),
        }};
        class XMLHttpRequest {
            open(_method, url) { if (url !== extensionURL + "inpage.js") { throw new Error("Unexpected content resource"); } }
            send() { this.responseText = providerSource; }
        }
        const contentContext = vm.createContext({browser, window: contentWindow, document: dom, URL, XMLHttpRequest,
            console: this.console(owner), ...this.scheduler.bindings(owner)});
        document.contentContext = contentContext;
        for (const name of ["protocol.generated.js", "bridge_wire.js", "content.js"]) {
            new vm.Script(sources.get(name), {filename: name}).runInContext(contentContext);
        }
        for (const provider of ["ethereum", "solana"]) {
            for (const event of ["connect", "disconnect", "accountsChanged", "accountChanged", "chainChanged"]) {
                pageWindow[provider]?.on(event, value => {
                    const entry = {provider, event, value: value?.toBase58 ? value.toBase58() : clone(value)};
                    document.events.push(entry);
                    this.trace({type: "provider-event", document: owner, tab: tab.id, profile: tab.profile.id, ...entry});
                });
            }
        }
        return document;
    }
    request(tabID, provider, payload, label = `operation-${++this.operationSerial}`) {
        const tab = this.tabs.get(tabID);
        if (!tab?.alive) { throw new Error("Unknown tab"); }
        const document = tab.document;
        const operation = {label, tab: tabID, document: document.owner, profileIdentifier: tab.profile.id, url: tab.url,
            provider, providerGeneration: document.contentContext.bigWalletProviderGeneration,
            publicState: publicProviderState(document, provider),
            payload: clone(payload), status: "pending", result: undefined, error: undefined};
        if (this.operations.has(label)) { throw new Error("Duplicate operation label"); }
        this.operations.set(label, operation);
        const promise = document.pageWindow[provider].request(clone(payload));
        const settle = (status, value) => {
            if (!document.alive) { return; }
            operation.status = status;
            if (status === "fulfilled") { operation.result = this.publicValue(value); }
            else { operation.error = {code: value?.code, message: value?.message || String(value),
                ...(value?.data === undefined ? {} : {data: clone(value.data)})}; }
            this.trace({type: "browser-settlement", ...operation});
            this.onSettlement({...operation, currentDocument: tab.document.owner});
        };
        promise.then(value => settle("fulfilled", value), error => settle("rejected", error)).catch(error => this.errors.push(error));
        return operation;
    }
    publicValue(value) {
        if (value?.publicKey?.toBase58) {
            return {...value, publicKey: value.publicKey.toBase58(), ...(ArrayBuffer.isView(value.signature) ? {signature: Buffer.from(value.signature).toString("hex")} : {})};
        }
        return clone(value);
    }
    navigate(tabID, url) {
        const tab = this.tabs.get(tabID);
        if (!tab?.alive) { throw new Error("Unknown tab"); }
        const old = tab.document;
        old.alive = false;
        this.scheduler.retire(old.owner);
        for (const operation of this.operations.values()) {
            if (operation.document === old.owner && operation.status === "pending") { operation.status = "abandoned"; }
        }
        tab.url = url;
        tab.profile.worker.tabUpdated?.(tab.id, {status: "loading", url});
        this.startDocument(tab);
    }
    replaceProvider(tabID) {
        const tab = this.tabs.get(tabID);
        const document = tab?.document;
        if (!document?.alive) { throw new Error("Unknown document"); }
        vm.runInContext(`{
            const generation = bigWalletNextGeneration();
            bigWalletProviderGeneration = generation;
            if (!bigWalletInjectProvider(generation)) { throw new Error("Provider replacement failed"); }
            bigWalletConfigurationState = undefined;
            void bigWalletLoadConfiguration(generation, 0, true);
        }`, document.contentContext);
    }
    focus(tabID) {
        const tab = this.tabs.get(tabID);
        tab.profile.activeTab = tabID;
        tab.document.dom.visibilityState = "visible";
        tab.document.contentEvents.dispatch("focus", {isTrusted: true}, tab.document.contentWindow);
    }
    configurationReady(tabID, expected) {
        const document = this.tabs.get(tabID)?.document;
        const cached = document?.contentContext.bigWalletConfigurationState;
        const delivered = document?.deliveredConfiguration;
        if (!document?.alive || !expected || !cached || !delivered || delivered.providerGeneration !== cached.providerGeneration) { return false; }
        for (const state of [cached.state, delivered.state]) {
            if (state.context !== expected.context || state.revisions.ethereum < expected.revisions.ethereum ||
                state.revisions.solana < expected.revisions.solana) { return false; }
            if (state.revisions.ethereum === expected.revisions.ethereum &&
                (state.ethereum.address.toLowerCase() !== expected.ethereum.address.toLowerCase() ||
                 state.ethereum.chainId !== expected.ethereum.chainId)) { return false; }
            if (state.revisions.solana === expected.revisions.solana &&
                (state.solana?.publicKey || null) !== (expected.solana?.publicKey || null)) { return false; }
        }
        return (document.pageWindow.ethereum.selectedAddress || "").toLowerCase() === cached.state.ethereum.address.toLowerCase() &&
            document.pageWindow.ethereum.chainId === cached.state.ethereum.chainId &&
            (document.pageWindow.solana.publicKey?.toBase58() || null) === (cached.state.solana?.publicKey || null);
    }
    restartWorker(profileIdentifier = null) {
        const profile = this.profile(profileIdentifier);
        profile.worker.alive = false;
        this.scheduler.retire(profile.worker.owner);
        this.startWorker(profile);
    }
    wake(profileIdentifier = null) {
        const profile = this.profile(profileIdentifier);
        profile.worker.alarm?.({name: "manualSwitchRecovery"});
    }
    toolbar(tabID) {
        const tab = this.tabs.get(tabID);
        tab.profile.worker.toolbar?.({id: tabID, url: tab.url, incognito: tab.privateBrowsing});
    }
    async openPopup(profileIdentifier = null) {
        const profile = this.profile(profileIdentifier);
        if (profile.popup) { return profile.popup; }
        const owner = `popup:${profile.id ?? "default"}:${++profile.popupSerial}`;
        const popup = {owner, alive: true, harness: null};
        profile.popup = popup;
        const isLive = () => popup.alive && profile.popup === popup;
        const tab = this.tabs.get(profile.activeTab);
        const harness = createPopupHarness({
            tab: tab ? {id: tab.id, url: tab.url, incognito: tab.privateBrowsing} : null,
            native: message => this.nativeMessage(profile, owner, message, isLive),
            worker: message => this.toWorker(profile, message, {id: extensionID, url: extensionURL + "popup.html"}, owner, isLive),
            tabMessage: message => tab ? this.toContent(tab.id, message, {id: extensionID, url: extensionURL + "popup.html"}, owner) : never(),
            storageGet: async () => Object.fromEntries(profile.storage),
            globals: this.scheduler.bindings(owner),
            onClose: () => {
                popup.alive = false;
                this.scheduler.retire(owner);
                if (profile.popup === popup) { profile.popup = null; }
            },
        });
        popup.harness = harness;
        await harness.boot();
        return popup;
    }
    closePopup(profileIdentifier = null) {
        const profile = this.profile(profileIdentifier);
        const popup = profile.popup;
        if (!popup) { return; }
        popup.alive = false;
        popup.harness.close();
        this.scheduler.retire(popup.owner);
        profile.popup = null;
    }
    popupState(profileIdentifier = null) {
        const popup = this.profile(profileIdentifier).popup;
        return popup ? vm.runInContext("popupQueue?.currentRequest?.state ?? null", popup.harness.context) : null;
    }
    popupPresentation(profileIdentifier = null) {
        const popup = this.profile(profileIdentifier).popup;
        return popup ? clone(vm.runInContext("popupQueue?.currentRequest?.presentation ?? null", popup.harness.context)) : null;
    }
    popupRequest(profileIdentifier = null) {
        const popup = this.profile(profileIdentifier).popup;
        return popup ? clone(vm.runInContext("popupQueue?.currentRequest?.request ?? null", popup.harness.context)) : null;
    }
    popupReviewing(profileIdentifier = null) {
        const popup = this.profile(profileIdentifier).popup;
        return popup ? vm.runInContext("popupQueue?.currentRequest ? popupQueue.isReviewing(popupQueue.currentRequest) : false", popup.harness.context) : false;
    }
    clickPopup(profileIdentifier, id) {
        const popup = this.profile(profileIdentifier).popup;
        if (!popup) { throw new Error("No popup"); }
        return popup.harness.get(id).click();
    }
    check() {
        if (this.errors.length) {
            if (this.errors[0] instanceof LifecycleFailure) { throw this.errors[0]; }
            throw new LifecycleFailure("browser", this.errors[0].message, {stack: this.errors[0].stack});
        }
    }
    snapshot() {
        return [...this.tabs.values()].filter(tab => tab.alive).map(tab => ({
            id: tab.id, profileIdentifier: tab.profile.id, url: tab.url, document: tab.document.owner,
            ethereum: {address: tab.document.pageWindow.ethereum?.selectedAddress, chainId: tab.document.pageWindow.ethereum?.chainId},
            solana: {address: tab.document.pageWindow.solana?.publicKey?.toBase58() ?? null},
            configuration: clone(tab.document.contentContext.bigWalletConfigurationState),
            events: clone(tab.document.events),
        }));
    }
    close() {
        for (const profile of this.profiles.values()) {
            this.closePopup(profile.id);
            profile.worker.alive = false;
            this.scheduler.retire(profile.worker.owner);
        }
        for (const tab of this.tabs.values()) { tab.document.alive = false; this.scheduler.retire(tab.document.owner); }
    }
}
